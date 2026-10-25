using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Ryujinx.Common.Utilities;

[StructLayout(LayoutKind.Sequential)]
unsafe struct ShaderControl
{
    internal uint version,size;
    internal ulong reserved,max_work,max_nodes,max_tracked_allocation_bytes;
    internal uint timeout_ms,reserved2;
    internal delegate* unmanaged[Cdecl]<void*,int> cancel;
    internal void* context;
}
sealed class ShaderBudgetStop : Exception
{
    internal readonly int Status;
    internal ShaderBudgetStop(int status) : base("shader resource control") { Status=status; }
}
// A single scope covers decoding, all optimizer/CFG passes, service retries,
// Cross, reflection and serialization. No process-wide GC/memory changes.
sealed unsafe class NativeTranslationBudget : IDisposable
{
    internal const ulong WorkCeiling=64UL*1024*1024,NodeCeiling=262144,TrackedCeiling=256UL*1024*1024;
    internal const uint TimeoutCeiling=5000;
    [ThreadStatic] internal static NativeTranslationBudget Current;
    ShaderControl control;
    readonly long start=Stopwatch.GetTimestamp(),allocated=GC.GetAllocatedBytesForCurrentThread();
    ulong work,nodes,tracked;
    internal static bool Valid(ShaderControl* value)
    {
        ShaderControl layout=default;
        bool compatible=sizeof(ShaderControl)==64 && (byte*)&layout.max_work-(byte*)&layout==16 &&
            (byte*)&layout.max_tracked_allocation_bytes-(byte*)&layout==32 && (byte*)&layout.timeout_ms-(byte*)&layout==40 &&
            (byte*)&layout.cancel-(byte*)&layout==48 && (byte*)&layout.context-(byte*)&layout==56;
        return compatible && (value==null ||
            (value->version==1 && value->size==64 && value->reserved==0 && value->reserved2==0 &&
             value->max_work<=WorkCeiling && value->max_nodes<=NodeCeiling &&
             value->max_tracked_allocation_bytes<=TrackedCeiling && value->timeout_ms<=TimeoutCeiling));
    }
    internal NativeTranslationBudget(ShaderControl* value)
    {
        control=value==null?default:*value;
        if(control.max_work==0)control.max_work=WorkCeiling;
        if(control.max_nodes==0)control.max_nodes=NodeCeiling;
        if(control.max_tracked_allocation_bytes==0)control.max_tracked_allocation_bytes=TrackedCeiling;
        if(control.timeout_ms==0)control.timeout_ms=TimeoutCeiling;
        if(Current!=null)throw new ShaderBudgetStop(4);
        Current=this;CanopyTranslationGuard.Checkpoint=Poll;
    }
    internal void Poll(ulong units=1,ulong addedNodes=0,ulong bytes=0)
    {
        if(units>control.max_work-work || addedNodes>control.max_nodes-nodes || bytes>control.max_tracked_allocation_bytes-tracked)throw new ShaderBudgetStop(5);
        work+=units;nodes+=addedNodes;tracked+=bytes;
        if(control.cancel!=null && control.cancel(control.context)!=0)throw new ShaderBudgetStop(6);
        if(Stopwatch.GetElapsedTime(start).TotalMilliseconds>=control.timeout_ms ||
           GC.GetAllocatedBytesForCurrentThread()-allocated>(long)control.max_tracked_allocation_bytes)throw new ShaderBudgetStop(5);
    }
    internal static void Check(ulong units=1,ulong nodes=0,ulong bytes=0) => Current?.Poll(units,nodes,bytes);
    internal static TimeSpan RegexTimeout {
        get {
            if(Current==null)return System.Text.RegularExpressions.Regex.InfiniteMatchTimeout;
            Current.Poll();return TimeSpan.FromMilliseconds(Math.Max(1,Current.control.timeout_ms-Stopwatch.GetElapsedTime(Current.start).TotalMilliseconds));
        }
    }
    public void Dispose() {
        // Module registers only its thread-local LiteralInteger pool cleanup;
        // aborted borrowed pools are discarded, never returned for reuse.
        try {CanopyTranslationGuard.Cleanup?.Invoke();}
        finally {CanopyTranslationGuard.Cleanup=null;CanopyTranslationGuard.Checkpoint=null;CanopyTranslationGuard.ResetDepth();Current=null;}
    }
    [UnmanagedCallersOnly(CallConvs=new[]{typeof(CallConvCdecl)})]
    internal static int CrossCheckpoint(void* context,ulong units,ulong nodes,ulong bytes)
    {
        try { ((NativeTranslationBudget)GCHandle.FromIntPtr((IntPtr)context).Target).Poll(units,nodes,bytes);return 0; }
        catch(ShaderBudgetStop stop){return stop.Status;}
        catch {return 3;}
    }
}
