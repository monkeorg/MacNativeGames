#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import "CanopyControllers.h"
#include <stdio.h>
#include <stdlib.h>

static void Check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
static void Notify(NSString *name, GCController *controller) {
    [NSNotificationCenter.defaultCenter postNotificationName:name object:controller];
}
static void Emit(GCController *controller) {
    GCExtendedGamepadValueChangedHandler handler=controller.extendedGamepad.valueChangedHandler;
    if (handler) handler(controller.extendedGamepad,controller.extendedGamepad.buttonA);
}
static uint64_t Identifier(CanopyControllers *bridge, NSUInteger index) {
    return [bridge.devices[index][@"id"] unsignedLongLongValue];
}
static struct mng_input Read(CanopyControllers *bridge,unsigned player,uint64_t expected) {
    struct mng_input input={0}; uint64_t identifier=0;
    Check([bridge readPlayer:player deviceID:&identifier input:&input]==MNG_PLAYER_OK,"player read failed");
    Check(identifier==expected,"player device changed"); return input;
}
static BOOL Neutral(struct mng_input input) {
    return input.buttons==0 && input.sticks[0]==0 && input.sticks[1]==0 &&
        input.sticks[2]==0 && input.sticks[3]==0 && input.triggers[0]==0 && input.triggers[1]==0;
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        Check(argc==2,"scenario required");
        NSString *scenario=[NSString stringWithUTF8String:argv[1]];
        // Public snapshot controllers exercise real GameController state and
        // the real bridge handlers; these are not hardware/device acceptance.
        GCController *first=[GCController controllerWithExtendedGamepad];
        GCController *second=[GCController controllerWithExtendedGamepad];
        Check(first.extendedGamepad && second.extendedGamepad,"snapshot controller unavailable");
        CanopyControllers *bridge=[CanopyControllers new];
        Check(bridge.devices.count==0,"test host unexpectedly has physical controllers");
        __block unsigned changes=0;
        bridge.stateDidChange=^{ changes++; };
        Notify(GCControllerDidConnectNotification,first);
        Notify(GCControllerDidConnectNotification,second);
        Check(bridge.devices.count==2 && changes>=2,"notification discovery failed");
        uint64_t a=Identifier(bridge,0), b=Identifier(bridge,1);
        Check(a && b && a!=b,"ephemeral IDs are not distinct");
        Check([bridge assignDevice:a toPlayer:0]==MNG_PLAYER_OK,"first assignment failed");
        Check([bridge assignDevice:b toPlayer:1]==MNG_PLAYER_OK,"second assignment failed");
        [first.extendedGamepad.buttonA setValue:1];
        [first.extendedGamepad.leftThumbstick.xAxis setValue:1];
        [second.extendedGamepad.buttonB setValue:1];
        [second.extendedGamepad.leftThumbstick.xAxis setValue:-1];
        Emit(first); Emit(second);
        if ([scenario isEqual:@"independent"]) {
            struct mng_input left=Read(bridge,0,a), right=Read(bridge,1,b);
            Check(left.buttons==1 && right.buttons==2 && left.sticks[0]==1 && right.sticks[0]==-1,"player inputs merged");
            Check([bridge assignDevice:b toPlayer:0]==MNG_PLAYER_CONFLICT,"occupied assignment accepted");
            Notify(GCControllerDidConnectNotification,first);
            Check(bridge.devices.count==2,"duplicate connect changed IDs");
            Check(first.handlerQueue==dispatch_get_main_queue(),"handler queue is not main");
        } else if ([scenario isEqual:@"disconnect"]) {
            Notify(GCControllerDidDisconnectNotification,first);
            Check(Neutral(Read(bridge,0,0)),"disconnect left held input");
            Emit(second); Check(Read(bridge,1,b).buttons==2,"disconnect released another player");
            Notify(GCControllerDidConnectNotification,first);
            uint64_t replacement=Identifier(bridge,1);
            Check(replacement>b && replacement!=a,"reconnected ID was reused");
            Check([bridge assignDevice:replacement toPlayer:0]==MNG_PLAYER_OK,"reconnect assignment failed");
            Check(Neutral(Read(bridge,0,replacement)),"reconnect inherited held state");
        } else if ([scenario isEqual:@"swap"]) {
            GCExtendedGamepadValueChangedHandler old=[first.extendedGamepad.valueChangedHandler copy];
            Check([bridge swapPlayer:0 withPlayer:1]==MNG_PLAYER_OK,"swap failed");
            old(first.extendedGamepad,first.extendedGamepad.buttonA);
            Check(Neutral(Read(bridge,1,a)) && Neutral(Read(bridge,0,b)),"stale swap callback changed input");
            Emit(first); Check(Read(bridge,1,a).buttons==1,"new swapped handler failed");
        } else if ([scenario isEqual:@"focus"]) {
            GCExtendedGamepadValueChangedHandler old=[first.extendedGamepad.valueChangedHandler copy];
            Check([bridge setFocused:NO]==MNG_PLAYER_OK,"deactivation failed");
            Emit(first); Check(Neutral(Read(bridge,0,a)),"unfocused input accepted");
            Check([bridge setFocused:YES]==MNG_PLAYER_OK,"reactivation failed");
            old(first.extendedGamepad,first.extendedGamepad.buttonA);
            Check(Neutral(Read(bridge,0,a)),"queued pre-focus event accepted");
            Emit(first); Check(Read(bridge,0,a).buttons==1,"fresh focus sample failed");
        } else if ([scenario isEqual:@"reassign"]) {
            GCExtendedGamepadValueChangedHandler other=[second.extendedGamepad.valueChangedHandler copy];
            GCExtendedGamepadValueChangedHandler old=[first.extendedGamepad.valueChangedHandler copy];
            Check([bridge unassignPlayer:0]==MNG_PLAYER_OK &&
                [bridge assignDevice:a toPlayer:2]==MNG_PLAYER_OK,"explicit reassignment failed");
            old(first.extendedGamepad,first.extendedGamepad.buttonA);
            Check(Neutral(Read(bridge,2,a)),"old assignment input survived");
            Check((id)other==(id)second.extendedGamepad.valueChangedHandler,"unaffected handler sequence was restarted");
            Emit(second); Check(Read(bridge,1,b).buttons==2,"unaffected player input lost");
        } else if ([scenario isEqual:@"teardown"]) {
            __weak CanopyControllers *weakBridge=bridge;
            GCExtendedGamepadValueChangedHandler old=[first.extendedGamepad.valueChangedHandler copy];
            bridge=nil;
            Check(weakBridge==nil,"bridge retained by handler or observer");
            Check(first.extendedGamepad.valueChangedHandler==nil && second.extendedGamepad.valueChangedHandler==nil,"handlers survived teardown");
            old(first.extendedGamepad,first.extendedGamepad.buttonA);
            Notify(GCControllerDidDisconnectNotification,first);
        } else Check(NO,"unknown scenario");
        puts("{\"status\":\"pass\",\"scope\":\"real GameController bridge with synthetic snapshot controllers; no hardware claim\"}");
    }
    return 0;
}
