#import <Foundation/Foundation.h>
#import "keyboard_input.h"
#include "keyboard_state.h"
#include <assert.h>
#include <stdio.h>

static unsigned downs[128], ups[128];
static unsigned clearCalls;
void runtime_input_key(unsigned code,int down) { assert(code < 128); if(down) downs[code]++; else ups[code]++; }
void runtime_input_keyboard_clear(void) { clearCalls++; }
static void emit(unsigned code,int down) { runtime_input_key(code,down); }
int main(int argc,const char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSString *mode = @(argv[1]);
        NSString *suite = [@"TOTKKeyboardProbe." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        TOTKKeyboardState state = {0};
        unsigned short bindings[TOTK_KEY_ACTIONS]; memcpy(bindings,totk_key_defaults,sizeof bindings);
        if ([mode isEqual:@"preferences"]) {
            for (unsigned i=0;i<TOTK_KEY_ACTIONS;i++) assert(TOTKKeyboardBinding(defaults,i) == bindings[i]);
            [defaults setObject:@"26" forKey:@"TOTK_KEY_BIND_0"]; assert(TOTKKeyboardBinding(defaults,0)==26);
            [defaults setObject:@YES forKey:@"TOTK_KEY_BIND_0"]; assert(TOTKKeyboardBinding(defaults,0)==26);
            [defaults setDouble:4.5 forKey:@"TOTK_KEY_BIND_0"]; assert(TOTKKeyboardBinding(defaults,0)==26);
            [defaults setInteger:41 forKey:@"TOTK_KEY_BIND_0"]; assert(TOTKKeyboardBinding(defaults,0)==26);
            assert([defaults objectForKey:@"TOTK_KEY_BIND_0"] == nil);
        } else if ([mode isEqual:@"persistence"]) {
            assert(TOTKKeyboardSetBinding(defaults,0,21));
            assert(clearCalls==1);
            [defaults synchronize];
            NSUserDefaults *again = [[NSUserDefaults alloc] initWithSuiteName:suite];
            assert(TOTKKeyboardBinding(again,0)==21);
            assert(TOTKKeyboardSetBinding(defaults,0,0)); assert(TOTKKeyboardBinding(defaults,0)==0);
        } else if ([mode isEqual:@"conflicts"]) {
            assert(!TOTKKeyboardSetBinding(defaults,0,4)); assert(TOTKKeyboardBinding(defaults,0)==26);
            assert(TOTKKeyboardSetBinding(defaults,1,0)); assert(TOTKKeyboardSetBinding(defaults,0,4));
            for (unsigned key=0;key<256;key++) if (key && !totk_key_supported(key)) assert(!TOTKKeyboardSetBinding(defaults,0,key));
            assert(!TOTKKeyboardSetBinding(defaults,TOTK_KEY_ACTIONS,0));
        } else if ([mode isEqual:@"safe_translation"]) {
            for (unsigned i=0;i<TOTK_KEY_ACTIONS;i++) {
                assert(totk_keyboard_event(&state,bindings[i],1,1,bindings,emit));
                assert(downs[totk_key_outputs[i]]==1);
                assert(totk_keyboard_event(&state,bindings[i],1,0,bindings,emit));
            }
            assert(!totk_keyboard_event(&state,41,1,1,bindings,emit));
            assert(!totk_keyboard_event(&state,30,1,1,bindings,emit));
            bindings[0]=30; assert(totk_keyboard_event(&state,30,1,1,bindings,emit));
            assert(downs[13]==2);
            for (unsigned code=18;code<=26;code++) assert(!downs[code]);
        } else if ([mode isEqual:@"sources"]) {
            assert(totk_keyboard_event(&state,26,1,1,bindings,emit));
            assert(!totk_keyboard_event(&state,26,2,0,bindings,emit)); assert(ups[13]==0);
            assert(totk_keyboard_event(&state,26,1,1,bindings,emit));
            assert(totk_keyboard_event(&state,26,2,1,bindings,emit)); assert(downs[13]==1);
            assert(totk_keyboard_event(&state,26,1,0,bindings,emit)); assert(ups[13]==1);
            assert(!totk_keyboard_event(&state,26,2,0,bindings,emit)); assert(ups[13]==1);
            totk_keyboard_event(&state,26,2,0,bindings,emit); assert(ups[13]==1);
        } else if ([mode isEqual:@"missing_source_release"]) {
            for (unsigned source=1;source<=2;source++) {
                assert(totk_keyboard_event(&state,26,1,1,bindings,emit));
                assert(totk_keyboard_event(&state,26,2,1,bindings,emit));
                assert(downs[13]==source && ups[13]==source-1);
                assert(totk_keyboard_event(&state,26,source,0,bindings,emit));
                assert(ups[13]==source && !state.sources[26] && !state.output[26] && !state.references[13]);
                assert(!totk_keyboard_event(&state,26,source,0,bindings,emit));
                assert(ups[13]==source);
            }
        } else if ([mode isEqual:@"release_mapping"]) {
            totk_keyboard_event(&state,26,2,1,bindings,emit);
            totk_keyboard_event(&state,26,1,1,bindings,emit);
            bindings[0]=21; bindings[1]=26;
            totk_keyboard_event(&state,26,1,0,bindings,emit);
            assert(ups[13]==1 && ups[0]==0);
            assert(!totk_keyboard_event(&state,26,2,0,bindings,emit));
            totk_keyboard_event(&state,26,2,1,bindings,emit); assert(downs[0]==1);
        } else if ([mode isEqual:@"references"]) {
            totk_keyboard_event(&state,26,1,1,bindings,emit);
            totk_keyboard_event(&state,26,2,1,bindings,emit);
            bindings[0]=21; totk_keyboard_event(&state,21,1,1,bindings,emit); assert(downs[13]==1);
            totk_keyboard_event(&state,26,1,0,bindings,emit); assert(ups[13]==0);
            totk_keyboard_event(&state,21,1,0,bindings,emit); assert(ups[13]==1);
        } else if ([mode isEqual:@"cleanup"]) {
            totk_keyboard_event(&state,26,1,1,bindings,emit); totk_keyboard_event(&state,26,2,1,bindings,emit);
            totk_keyboard_event(&state,13,2,1,bindings,emit);
            totk_keyboard_clear(&state,emit); assert(ups[13]==1 && ups[38]==1);
            totk_keyboard_clear(&state,emit);
            totk_keyboard_event(&state,26,1,0,bindings,emit); assert(ups[13]==1);
            totk_keyboard_event(&state,26,2,1,bindings,emit); assert(downs[13]==2);
        } else assert(!"unknown test");
        [defaults removePersistentDomainForName:suite];
        puts("PASS");
    }
    return 0;
}
