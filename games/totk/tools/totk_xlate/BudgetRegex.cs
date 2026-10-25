using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

// Retains CLI patterns/options and unlimited CLI semantics. Only the native
// request scope supplies cooperative remaining-time and match/growth quotas.
sealed class BudgetRegex
{
    readonly string pattern;readonly RegexOptions options;readonly Regex original;
    internal BudgetRegex(string pattern,RegexOptions options=RegexOptions.None) {this.pattern=pattern;this.options=options;original=new Regex(pattern,options);}
    Regex Bounded(string input) {
        NativeTranslationBudget.Check(1,0,checked((ulong)input.Length*2));
        return NativeTranslationBudget.Current==null?original:new Regex(pattern,options,NativeTranslationBudget.RegexTimeout);
    }
    internal Match Match(string input,int start=0)=>Bounded(input).Match(input,start);
    internal bool IsMatch(string input)=>Bounded(input).IsMatch(input);
    internal IEnumerable<Match> Matches(string input) {
        foreach(Match match in Bounded(input).Matches(input)) {NativeTranslationBudget.Check(1,1,128);yield return match;}
    }
    internal string Replace(string input,string replacement)=>Bounded(input).Replace(input,replacement);
    internal string Replace(string input,MatchEvaluator replacement,int count=int.MaxValue)=>Bounded(input).Replace(input,replacement,count);
    internal static string Escape(string input)=>Regex.Escape(input);
    internal static Match Match(string input,string pattern,RegexOptions options=RegexOptions.None)=>new BudgetRegex(pattern,options).Match(input);
    internal static bool IsMatch(string input,string pattern)=>new BudgetRegex(pattern).IsMatch(input);
    internal static IEnumerable<Match> Matches(string input,string pattern,RegexOptions options=RegexOptions.None)=>new BudgetRegex(pattern,options).Matches(input);
    internal static string Replace(string input,string pattern,string replacement)=>new BudgetRegex(pattern).Replace(input,replacement);
    internal static string Replace(string input,string pattern,MatchEvaluator replacement)=>new BudgetRegex(pattern).Replace(input,replacement);
}
