// Original bounded C ABI over the existing patched translator/service core.
// All pointers must reference valid caller-owned nonoverlapping memory.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using Ryujinx.Common.Utilities;

static unsafe class NativeExports
{
#if CANOPY_STATIC
    const string CrossLibrary = "__Internal";
#else
    const string CrossLibrary = "canopy_spirv_cross";
#endif
    [DllImport(CrossLibrary, EntryPoint = "canopy_spirv_cross", CallingConvention = CallingConvention.Cdecl)]
    static extern int Cross(byte* words, nuint length, byte* text, nuint capacity, nuint* written);
    [DllImport(CrossLibrary,EntryPoint="canopy_spirv_cross_controlled",CallingConvention=CallingConvention.Cdecl)]
    static extern int CrossControlled(byte* words,nuint length,byte* text,nuint capacity,nuint* written,
        delegate* unmanaged[Cdecl]<void*,ulong,ulong,ulong,int> checkpoint,void* context);
    static int active;
    static readonly UTF8Encoding Utf8 = new(false, true);
    [UnmanagedCallersOnly(EntryPoint = "canopy_shader_abi_version")]
    public static uint Version() => 1;

    static void Validate(JsonObject rq)
    {
        var allowed = new HashSet<string> {"variant","stage","chain","c1","tex","img","attr","fout","local","depth_minus_w","debug"};
        foreach(var kv in rq) if(!allowed.Contains(kv.Key)) throw new ArgumentException();
        if(rq["variant"] is not JsonValue v || !v.TryGetValue<string>(out var variant) ||
           !Regex.IsMatch(variant,"\\A[0-9a-f]{64}-[0-9a-f]{12}\\z")) throw new ArgumentException();
        string stage=rq["stage"]?.GetValue<string>();
        if(stage!="cs" && stage!="vs" && stage!="ps") throw new ArgumentException();
        string chain=rq["chain"]?.GetValue<string>();
        if(string.IsNullOrEmpty(chain) || chain.Length>128 || chain.IndexOfAny(new[]{'\0','\r','\n'})>=0)throw new ArgumentException();
        if(rq["c1"] is JsonNode c1 && (c1.GetValue<string>().Length>8192 || !Regex.IsMatch(c1.GetValue<string>(),"\\A(?:[0-9a-fA-F]{2})*\\z")))throw new ArgumentException();
        foreach(string kind in new[]{"tex","img","attr","fout"}) if(rq[kind] is JsonNode node) {
            if(node is not JsonObject table || table.Count>1024)throw new ArgumentException();
            foreach(var kv in table) {
                int limit=kind=="attr"?32:kind=="fout"?8:1024;
                if(!int.TryParse(kv.Key,out int slot) || slot<0 || slot>=limit || kv.Key!=slot.ToString(System.Globalization.CultureInfo.InvariantCulture))throw new ArgumentException();
                if(kind=="img") {
                    if(kv.Value is not JsonObject image || image.Count>2)throw new ArgumentException();
                    foreach(var imageKV in image) if((imageKV.Key!="type" && imageKV.Key!="fmt") || imageKV.Value is not JsonValue imageValue ||
                        !imageValue.TryGetValue<string>(out string imageText) || imageText.Length>64)throw new ArgumentException();
                } else if(kv.Value is not JsonValue scalarValue || !scalarValue.TryGetValue<string>(out string scalarText) || scalarText.Length>64)throw new ArgumentException();
            }
        }
        if(rq["local"] is JsonNode local) {
            if(local is not JsonArray dims || dims.Count!=3)throw new ArgumentException();
            long product=1;foreach(var dimension in dims) {int n=dimension.GetValue<int>();if(n<1 || n>1024)throw new ArgumentException();product*=n;}
            if(product>1024)throw new ArgumentException();
        } else if(stage=="cs")throw new ArgumentException();
        foreach(string key in new[]{"debug","depth_minus_w"})if(rq[key] is JsonNode flag)_=flag.GetValue<bool>();
    }
    static string ToMetal(byte[] spirv)
    {
        NativeTranslationBudget.Check(1,0,8UL<<20);
        byte[] output=new byte[8<<20];nuint written=0;
        GCHandle handle=GCHandle.Alloc(NativeTranslationBudget.Current);
        try {fixed(byte* input=spirv)fixed(byte* text=output) {
            int status=CrossControlled(input,(nuint)spirv.Length,text,(nuint)output.Length,&written,&NativeTranslationBudget.CrossCheckpoint,(void*)GCHandle.ToIntPtr(handle));
            if(status==5 || status==6)throw new ShaderBudgetStop(status);
            if(status!=0 || written>(nuint)output.Length)throw new InvalidOperationException();
        }} finally {handle.Free();}
        NativeTranslationBudget.Check(1,0,(ulong)written*2);
        return Utf8.GetString(output,0,checked((int)written));
    }
    [UnmanagedCallersOnly(EntryPoint = "canopy_shader_translate")]
    public static int Translate(byte* code,nuint codeLength,byte* request,nuint requestLength,
        byte* output,nuint capacity,nuint* outLength)
        => TranslateControlledCore(code,codeLength,request,requestLength,output,capacity,outLength,null);
    [UnmanagedCallersOnly(EntryPoint="canopy_shader_translate_controlled")]
    public static int TranslateControlled(byte* code,nuint codeLength,byte* request,nuint requestLength,
        byte* output,nuint capacity,nuint* outLength,ShaderControl* control)
        => TranslateControlledCore(code,codeLength,request,requestLength,output,capacity,outLength,control);
    static int TranslateControlledCore(byte* code,nuint codeLength,byte* request,nuint requestLength,
        byte* output,nuint capacity,nuint* outLength,ShaderControl* control)
    {
        if(outLength==null)return 1;*outLength=0;
        if(code==null || request==null || (output==null && capacity!=0) || codeLength<16 || codeLength>65536 ||
           (codeLength&7)!=0 || requestLength==0 || requestLength>65536 || capacity>(16u<<20) || !NativeTranslationBudget.Valid(control))return 1;
        if(Interlocked.CompareExchange(ref active,1,0)!=0)return 4;
        try {
            using var budget=new NativeTranslationBudget(control);
            budget.Poll(1,0,(ulong)(codeLength+requestLength)*4);
            var rq=JsonNode.Parse(Utf8.GetString(new ReadOnlySpan<byte>(request,(int)requestLength)),
                documentOptions:new JsonDocumentOptions {MaxDepth=16}) as JsonObject;
            if(rq==null)return 1;Validate(rq);
            if(rq["stage"].GetValue<string>()!="cs" && codeLength<0x60)return 1;
            byte[] bytes=new ReadOnlySpan<byte>(code,(int)codeLength).ToArray();
            if(rq["stage"].GetValue<string>()!="cs") {
                uint word=(uint)(bytes[0]|bytes[1]<<8|bytes[2]<<16|bytes[3]<<24);
                uint stage=(word>>10)&15;
                if(stage!=(rq["stage"].GetValue<string>()=="vs"?1u:5u))return 1;
            }
            var result=ShaderService.TranslateBytes(rq,bytes,rq["chain"].GetValue<string>(),rq["debug"]?.GetValue<bool>() ?? false,ToMetal,true);
            var envelope=new JsonObject { ["spirv_base64"]=Convert.ToBase64String(result.spirv),["metal"]=result.metal,
                ["reflection"]=JsonNode.Parse(result.reflection) };
            byte[] encoded=Utf8.GetBytes(envelope.ToJsonString());
            budget.Poll(1,0,(ulong)encoded.Length);
            if(encoded.Length>(16<<20))return 5;
            *outLength=(nuint)encoded.Length;
            if(capacity<(nuint)encoded.Length)return 2;
            encoded.AsSpan().CopyTo(new Span<byte>(output,(int)capacity));return 0;
        }
        catch(ShaderBudgetStop stop){return stop.Status;}
        catch(CanopyBudgetExceededException){return 5;}
        catch(RegexMatchTimeoutException){return 5;}
        catch(ArgumentException){return 1;}
        catch(JsonException){return 1;}
        catch(Exception){return 3;}
        finally{Volatile.Write(ref active,0);}
    }
}
