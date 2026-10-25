#import "CanopyTouchPad.h"
#include <math.h>

@interface CanopyTouchPad ()
- (BOOL)activateButton:(uint16_t)bit;
@end
@interface CanopyTouchAccessibilityElement : UIAccessibilityElement
@property(nonatomic,weak) CanopyTouchPad *pad;
@property(nonatomic) uint16_t bit;
@end
@implementation CanopyTouchAccessibilityElement
- (BOOL)accessibilityActivate { return [self.pad activateButton:self.bit]; }
@end

@implementation CanopyTouchPad {
    struct mng_touch _state;
    NSMapTable<UITouch *,NSNumber *> *_contacts;
    uint64_t _nextContact;
    CGRect _area;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.backgroundColor=UIColor.clearColor;self.multipleTouchEnabled=YES;
        self.contentMode=UIViewContentModeRedraw;
        self.accessibilityIdentifier=@"CanopyTouchControls";
        _contacts=[NSMapTable strongToStrongObjectsMapTable];
    }
    return self;
}
- (void)cancelInput { mng_touch_cancel(&_state);[_contacts removeAllObjects];[self setNeedsDisplay]; }
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
    if(!self.userInteractionEnabled || self.hidden || !_state.radius)return NO;
    _state.edges|=bit;return YES;
}
- (NSArray *)accessibilityElements {
    if(!self.userInteractionEnabled || self.hidden || !_state.radius)return @[];
    NSArray *labels=@[@"A",@"B",@"X",@"Y",@"ZL",@"L",@"R",@"ZR",@"Minus",@"Plus",@"D-pad left",@"D-pad up",@"D-pad right",@"D-pad down",@"Left stick press",@"Right stick press"];
    NSMutableArray *elements=[NSMutableArray array];
    for(unsigned i=0;i<16;i++) {
        CanopyTouchAccessibilityElement *element=[[CanopyTouchAccessibilityElement alloc] initWithAccessibilityContainer:self];
        element.pad=self;element.bit=_state.buttons[i].bit;element.accessibilityLabel=labels[i];
        element.accessibilityTraits=UIAccessibilityTraitButton;
        element.accessibilityHint=@"Sends one button press to the selected local player.";
        element.accessibilityFrameInContainerSpace=CGRectMake(_state.buttons[i].x-22,_state.buttons[i].y-22,44,44);
        [elements addObject:element];
    }
    return [elements copy];
}
- (void)consumeInput:(struct mng_input *)input { (void)mng_touch_consume(&_state,input); }
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;if(!self.userInteractionEnabled || self.hidden)return;
    for(UITouch *touch in touches) {
        if(touch.type!=UITouchTypeDirect || _nextContact==UINT64_MAX)continue;
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
