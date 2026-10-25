#import "CanopyTouchPad.h"
#include <math.h>

@interface CanopyTouchPad ()
- (BOOL)activateButton:(uint16_t)bit;
- (BOOL)canAcceptInput;
- (BOOL)setAccessibleStick:(unsigned)stick epoch:(uint64_t)epoch x:(float)x y:(float)y;
- (uint64_t)focusAccessibleStick:(unsigned)stick;
- (void)releaseAccessibleStick:(unsigned)stick epoch:(uint64_t)epoch;
- (void)releaseAccessibleStick:(unsigned)stick;
@end
@interface CanopyTouchAccessibilityElement : UIAccessibilityElement
@property(nonatomic,weak) CanopyTouchPad *pad;
@property(nonatomic) uint16_t bit;
@end
@implementation CanopyTouchAccessibilityElement
- (BOOL)accessibilityActivate { return [self.pad activateButton:self.bit]; }
@end

// These contacts belong to this session-local touch source, not the controller
// router. A direction is held until Neutral or focus/capture cancellation.
@interface CanopyStickAccessibilityElement : UIAccessibilityElement
@property(nonatomic,weak) CanopyTouchPad *pad;
@property(nonatomic) unsigned stick;
@end
@implementation CanopyStickAccessibilityElement {
    uint64_t _focusEpoch;
}
- (BOOL)setX:(float)x y:(float)y value:(NSString *)value epoch:(uint64_t)epoch {
    if(epoch!=_focusEpoch || UIAccessibilityFocusedElement(UIAccessibilityNotificationVoiceOverIdentifier)!=self)return NO;
    if(![self.pad setAccessibleStick:self.stick epoch:epoch x:x y:y])return NO;
    self.accessibilityValue=value;return YES;
}
- (void)refreshActions {
    // Each action captures its focus epoch: retaining an old rotor action cannot
    // make it acquire the token of a later focus session on this stable element.
    uint64_t epoch=_focusEpoch;
    __weak CanopyStickAccessibilityElement *element=self;
    NSArray<NSString *> *names=@[@"Up",@"Down",@"Left",@"Right",@"Neutral"];
    NSMutableArray *actions=[NSMutableArray array];
    for(unsigned i=0;i<names.count;i++) {
        float x=i==2?-1:i==3?1:0,y=i==0?1:i==1?-1:0;
        NSString *name=names[i];
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:name actionHandler:^BOOL(UIAccessibilityCustomAction *action) {
            (void)action;return [element setX:x y:y value:name epoch:epoch];
        }]];
    }
    self.accessibilityCustomActions=actions;
}
- (BOOL)accessibilityActivate { return [self setX:0 y:0 value:@"Neutral" epoch:_focusEpoch]; }
- (void)accessibilityElementDidBecomeFocused {
    [super accessibilityElementDidBecomeFocused];
    _focusEpoch=[self.pad focusAccessibleStick:self.stick];[self refreshActions];
}
- (void)accessibilityElementDidLoseFocus {
    // A delayed loss notification after this same element regained focus must
    // not release the newer contact. The pad also rejects cancelled epochs.
    if(UIAccessibilityFocusedElement(UIAccessibilityNotificationVoiceOverIdentifier)!=self) {
        [self.pad releaseAccessibleStick:self.stick epoch:_focusEpoch];self.accessibilityValue=@"Neutral";
    }
    [super accessibilityElementDidLoseFocus];
}
@end

@implementation CanopyTouchPad {
    struct mng_touch _state;
    NSMapTable<UITouch *,NSNumber *> *_contacts;
    uint64_t _nextContact;
    uint64_t _accessibleContacts[2];
    uint64_t _accessibleEpochs[2];
    NSArray<UIAccessibilityElement *> *_accessibleElements;
    CGRect _area;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.backgroundColor=UIColor.clearColor;self.multipleTouchEnabled=YES;
        self.contentMode=UIViewContentModeRedraw;
        self.accessibilityIdentifier=@"CanopyTouchControls";
        _contacts=[NSMapTable strongToStrongObjectsMapTable];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sceneWillDeactivate:) name:UISceneWillDeactivateNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowDidResignKey:) name:UIWindowDidResignKeyNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(voiceOverStatusChanged:) name:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)applicationWillResignActive:(NSNotification *)notification { (void)notification;[self cancelInput]; }
- (void)sceneWillDeactivate:(NSNotification *)notification { if(notification.object==self.window.windowScene)[self cancelInput]; }
- (void)windowDidResignKey:(NSNotification *)notification { if(notification.object==self.window)[self cancelInput]; }
- (void)voiceOverStatusChanged:(NSNotification *)notification {
    (void)notification;if(!UIAccessibilityIsVoiceOverRunning()){[self releaseAccessibleStick:0];[self releaseAccessibleStick:1];}
}
- (void)cancelInput {
    [self releaseAccessibleStick:0];[self releaseAccessibleStick:1];
    mng_touch_cancel(&_state);
    [_contacts removeAllObjects];[self setNeedsDisplay];
}
- (void)setHidden:(BOOL)hidden { if(hidden)[self cancelInput];[super setHidden:hidden]; }
- (BOOL)canAcceptInput {
    if(!self.window.isKeyWindow || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive || !_state.radius)return NO;
    if(self.window.windowScene && self.window.windowScene.activationState!=UISceneActivationStateForegroundActive)return NO;
    for(UIView *view=self;view;view=view.superview)if(view.hidden || !view.userInteractionEnabled || view.alpha<=.01)return NO;
    return YES;
}
- (void)releaseAccessibleStick:(unsigned)stick {
    if(stick>=2)return;
    if(_accessibleContacts[stick])(void)mng_touch_end(&_state,_accessibleContacts[stick]);
    _accessibleContacts[stick]=0;
    // Never wrap: an exhausted epoch permanently refuses further acquisition.
    if(_accessibleEpochs[stick]!=UINT64_MAX)++_accessibleEpochs[stick];
    [self setNeedsDisplay];
}
- (uint64_t)focusAccessibleStick:(unsigned)stick {
    if(stick>=2 || ![self canAcceptInput])return 0;
    [self releaseAccessibleStick:stick];
    return _accessibleEpochs[stick]==UINT64_MAX?0:_accessibleEpochs[stick];
}
- (void)releaseAccessibleStick:(unsigned)stick epoch:(uint64_t)epoch {
    if(stick<2 && epoch && epoch==_accessibleEpochs[stick])[self releaseAccessibleStick:stick];
}
- (BOOL)setAccessibleStick:(unsigned)stick epoch:(uint64_t)epoch x:(float)x y:(float)y {
    if(stick>=2 || !epoch || epoch!=_accessibleEpochs[stick] || epoch==UINT64_MAX || ![self canAcceptInput])return NO;
    if(x==0 && y==0) {
        // Neutral retains focus ownership so another direction needs no refocus.
        if(_accessibleContacts[stick])(void)mng_touch_end(&_state,_accessibleContacts[stick]);
        _accessibleContacts[stick]=0;[self setNeedsDisplay];return YES;
    }
    // Never displace a finger's contact or synthesize a button while finding a
    // stick origin. The normal touch engine remains the sole axis producer.
    for(unsigned i=0;i<MNG_TOUCH_CONTACTS;i++)if(_state.contacts[i].id && _state.contacts[i].role==stick+1 && _state.contacts[i].id!=_accessibleContacts[stick])return NO;
    if(!_accessibleContacts[stick]) {
        if(_nextContact==UINT64_MAX)return NO;
        float ox=_state.x+_state.width*(stick?.68f:.32f),oy=_state.y+_state.height*.8f;
        for(unsigned i=0;i<16;i++)if(hypotf(ox-_state.buttons[i].x,oy-_state.buttons[i].y)<_state.hit_radius)return NO;
        uint64_t identifier=++_nextContact;
        if(mng_touch_begin(&_state,identifier,ox,oy,1)!=0)return NO;
        _accessibleContacts[stick]=identifier;
    }
    for(unsigned i=0;i<MNG_TOUCH_CONTACTS;i++)if(_state.contacts[i].id==_accessibleContacts[stick]) {
        struct mng_touch_contact contact=_state.contacts[i];
        if(mng_touch_move(&_state,contact.id,contact.origin_x+x*_state.radius,contact.origin_y-y*_state.radius)==0){[self setNeedsDisplay];return YES;}
        break;
    }
    [self releaseAccessibleStick:stick];return NO;
}
- (void)setUserInteractionEnabled:(BOOL)enabled { if(!enabled)[self cancelInput];[super setUserInteractionEnabled:enabled]; }
- (void)willMoveToWindow:(UIWindow *)window { if(!window)[self cancelInput];[super willMoveToWindow:window]; }
- (void)layoutSubviews {
    [super layoutSubviews];CGRect area=UIEdgeInsetsInsetRect(self.bounds,self.safeAreaInsets);
    if(!CGRectEqualToRect(area,_area)) {
        [self cancelInput];_area=area;
        if(mng_touch_layout(&_state,area.origin.x,area.origin.y,area.size.width,area.size.height)!=0)memset(&_state,0,sizeof(_state));
    }
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange];[self setNeedsLayout]; }
- (BOOL)activateButton:(uint16_t)bit {
    if(![self canAcceptInput])return NO;
    _state.edges|=bit;return YES;
}
- (NSArray *)accessibilityElements {
    if(![self canAcceptInput])return @[];
    if(!_accessibleElements) {
        NSArray *labels=@[@"A",@"B",@"X",@"Y",@"ZL",@"L",@"R",@"ZR",@"Minus",@"Plus",@"D-pad left",@"D-pad up",@"D-pad right",@"D-pad down",@"Left stick press",@"Right stick press"];
        NSMutableArray *elements=[NSMutableArray array];
        for(unsigned i=0;i<16;i++) {
            CanopyTouchAccessibilityElement *element=[[CanopyTouchAccessibilityElement alloc] initWithAccessibilityContainer:self];
            element.pad=self;element.accessibilityLabel=labels[i];
            element.accessibilityTraits=UIAccessibilityTraitButton;
            element.accessibilityHint=@"Sends one button press to the selected local player.";
            [elements addObject:element];
        }
        for(unsigned stick=0;stick<2;stick++) {
            CanopyStickAccessibilityElement *element=[[CanopyStickAccessibilityElement alloc] initWithAccessibilityContainer:self];
            element.pad=self;element.stick=stick;
            element.accessibilityLabel=stick?@"Right analog stick":@"Left analog stick";
            element.accessibilityTraits=UIAccessibilityTraitButton;
            element.accessibilityHint=@"Choose a direction in Actions to hold it. Neutral or leaving this control releases it. Double-tap for Neutral. After input cancellation, leave and return to this control.";
            [element refreshActions];[elements addObject:element];
        }
        _accessibleElements=[elements copy];
    }
    // Keep element identities stable across layout/value queries. Only geometry
    // and the current value change; focus epochs are never renewed by a getter.
    for(unsigned i=0;i<16;i++) {
        CanopyTouchAccessibilityElement *element=(CanopyTouchAccessibilityElement *)_accessibleElements[i];
        element.bit=_state.buttons[i].bit;
        element.accessibilityFrameInContainerSpace=CGRectMake(_state.buttons[i].x-22,_state.buttons[i].y-22,44,44);
    }
    for(unsigned stick=0;stick<2;stick++) {
        CanopyStickAccessibilityElement *element=(CanopyStickAccessibilityElement *)_accessibleElements[16+stick];
        float x=_state.input.sticks[stick*2],y=_state.input.sticks[stick*2+1];
        element.accessibilityValue=_accessibleContacts[stick]?(x<0?@"Left":x>0?@"Right":y>0?@"Up":y<0?@"Down":@"Neutral"):@"Neutral";
        element.accessibilityFrameInContainerSpace=CGRectMake(_state.x+_state.width*(stick?.68f:.32f)-_state.radius,_state.y+_state.height*.8f-_state.radius,2*_state.radius,2*_state.radius);
    }
    return _accessibleElements;
}
- (void)consumeInput:(struct mng_input *)input { if(![self canAcceptInput])[self cancelInput];(void)mng_touch_consume(&_state,input); }
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;if(![self canAcceptInput])return;
    for(UITouch *touch in touches) {
        if(touch.type!=UITouchTypeDirect || _nextContact==UINT64_MAX)continue;
        [self releaseAccessibleStick:0];[self releaseAccessibleStick:1];
        CGPoint at=[touch locationInView:self];uint64_t identifier=++_nextContact;
        if(mng_touch_begin(&_state,identifier,at.x,at.y,1)==0)[_contacts setObject:@(identifier) forKey:touch];
    }
    [self setNeedsDisplay];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;if(!self.userInteractionEnabled || self.hidden)return;
    for(UITouch *touch in touches) {
        NSNumber *identifier=[_contacts objectForKey:touch];if(!identifier || touch.type!=UITouchTypeDirect)continue;
        CGPoint at=[touch locationInView:self];(void)mng_touch_move(&_state,identifier.unsignedLongLongValue,at.x,at.y);
    }
    [self setNeedsDisplay];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for(UITouch *touch in touches) {
        NSNumber *identifier=[_contacts objectForKey:touch];if(identifier)(void)mng_touch_end(&_state,identifier.unsignedLongLongValue);
        [_contacts removeObjectForKey:touch];
    }
    [self setNeedsDisplay];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // Cancellation drops pending short taps too; a menu must never replay them.
    (void)touches;(void)event;[self cancelInput];
}
- (void)drawRect:(CGRect)rect {
    (void)rect;if(!_state.radius)return;
    CGContextRef context=UIGraphicsGetCurrentContext();
    UIColor *ink=[UIColor colorWithWhite:1 alpha:.65],*fill=[UIColor colorWithWhite:0 alpha:.22];
    CGContextSetStrokeColorWithColor(context,ink.CGColor);CGContextSetLineWidth(context,2);
    NSArray *labels=@[@"A",@"B",@"X",@"Y",@"ZL",@"L",@"R",@"ZR",@"−",@"+",@"◀",@"▲",@"▶",@"▼",@"L3",@"R3"];
    UIFont *font=[UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold] maximumPointSize:20];
    NSDictionary *attributes=@{NSFontAttributeName:font,NSForegroundColorAttributeName:ink};
    for(unsigned i=0;i<16;i++) {
        struct mng_touch_button button=_state.buttons[i];CGRect box=CGRectMake(button.x-22,button.y-22,44,44);
        CGContextSetFillColorWithColor(context,fill.CGColor);CGContextFillEllipseInRect(context,box);CGContextStrokeEllipseInRect(context,box);
        NSString *label=labels[i];CGSize size=[label sizeWithAttributes:attributes];[label drawAtPoint:CGPointMake(button.x-size.width/2,button.y-size.height/2) withAttributes:attributes];
    }
    for(unsigned stick=0;stick<2;stick++) {
        CGPoint origin=CGPointMake(_state.x+_state.width*(stick?.68:.32),_state.y+_state.height*.8);
        CGPoint point=origin;
        for(unsigned i=0;i<MNG_TOUCH_CONTACTS;i++)if(_state.contacts[i].id && _state.contacts[i].role==stick+1) {
            origin=CGPointMake(_state.contacts[i].origin_x,_state.contacts[i].origin_y);point=CGPointMake(_state.contacts[i].x,_state.contacts[i].y);break;
        }
        float dx=point.x-origin.x,dy=point.y-origin.y,distance=hypotf(dx,dy);
        if(distance>_state.radius){dx*=_state.radius/distance;dy*=_state.radius/distance;}
        CGContextStrokeEllipseInRect(context,CGRectMake(origin.x-_state.radius,origin.y-_state.radius,2*_state.radius,2*_state.radius));
        CGContextSetFillColorWithColor(context,fill.CGColor);CGContextFillEllipseInRect(context,CGRectMake(origin.x+dx-20,origin.y+dy-20,40,40));
    }
}
@end
