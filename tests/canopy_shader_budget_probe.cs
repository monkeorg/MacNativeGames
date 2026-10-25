using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using Ryujinx.Common.Utilities;

static unsafe class ShaderBudgetProbe
{
    static void Require(bool value) {if(!value)throw new Exception("original budget fixture failed");}
    static void Stops(Action action,int expected) {try{action();}catch(ShaderBudgetStop stop){Require(stop.Status==expected);return;}throw new Exception("missing budget refusal");}
    [UnmanagedCallersOnly(CallConvs=new[]{typeof(CallConvCdecl)})]
    static int Cancel(void* context) => *(int*)context;
    static void Recurse(int depth) {using var scope=CanopyTranslationGuard.Enter();if(depth>0)Recurse(depth-1);}
    static int Main()
    {
        ShaderControl control=default;control.version=1;control.size=64;Require(NativeTranslationBudget.Valid(&control));
        control.reserved=1;Require(!NativeTranslationBudget.Valid(&control));control.reserved=0;
        control.max_work=3;
        using(var budget=new NativeTranslationBudget(&control)) {
            budget.Poll(1);CanopyTranslationGuard.Step(1);budget.Poll(1);
            Stops(()=>CanopyTranslationGuard.Step(1),5); // Retry shares remaining0.
        }
        control.max_work=0;control.max_nodes=2;
        using(var budget=new NativeTranslationBudget(&control)) {budget.Poll(0,2);Stops(()=>budget.Poll(0,1),5);}
        control.max_nodes=0;control.max_tracked_allocation_bytes=1024*1024;
        using(var budget=new NativeTranslationBudget(&control)) {budget.Poll(0,0,1024*1024);Stops(()=>budget.Poll(0,0,1),5);}
        control.max_tracked_allocation_bytes=0;int cancelled=0;control.cancel=&Cancel;control.context=&cancelled;
        using(var budget=new NativeTranslationBudget(&control)) {budget.Poll();cancelled=1;Stops(()=>budget.Poll(),6);}
        control.cancel=null;control.context=null;control.timeout_ms=1;
        using(var budget=new NativeTranslationBudget(&control)) {Thread.Sleep(5);Stops(()=>budget.Poll(),5);}
        control.timeout_ms=0;
        using(var budget=new NativeTranslationBudget(&control)) {
            bool refused=false;try{Recurse(300);}catch(CanopyBudgetExceededException){refused=true;}Require(refused);
        }
        int cleaned=0;
        using(var budget=new NativeTranslationBudget(&control)) {CanopyTranslationGuard.Cleanup=()=>cleaned++;}
        Require(cleaned==1 && NativeTranslationBudget.Current==null && CanopyTranslationGuard.Checkpoint==null && CanopyTranslationGuard.Cleanup==null);
        using(var budget=new NativeTranslationBudget(&control)) {
            Require(new BudgetRegex("main[0-9]+").IsMatch("kernel main0"));
            int matches=0;foreach(Match match in new BudgetRegex("a").Matches("aaa")){Require(match.Success);matches++;}Require(matches==3);
        }
        Console.WriteLine("{\"status\":0}");return 0;
    }
}
