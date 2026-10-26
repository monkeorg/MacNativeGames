/* Original Canopy glue for the pinned MIT nxnative host. No game payload. */
#ifndef CANOPY_MK8DX_H
#define CANOPY_MK8DX_H
#include "mng_apple_host.h"
#include <stdint.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import "CanopyRomFS.h"
@interface MKPrepared : NSObject
@property(nonatomic,copy) NSString *modules;
@property(nonatomic,copy) NSString *romfs;
@property(nonatomic,copy) NSString *seed;
@property(nonatomic,copy) NSString *runtime;
@property(nonatomic,copy) NSString *active;
@property(nonatomic,copy) NSString *identity;
@property(nonatomic,copy) NSString *language;
@property(nonatomic) uint64_t uidLow,uidHigh;
@property(nonatomic) int namespaceFD,leaseFD;
@property(nonatomic,strong) CanopyRomFSLease *romfsLease;
@property(nonatomic,strong) id<MTLDevice> device;
@end
MKPrepared *MKPreparedObject(struct mng_apple_prepared *);
int MKPrepare(const struct mng_apple_prepare *,struct mng_apple_prepared **);
void MKReleasePrepared(struct mng_apple_prepared *);
int MKAttach(const struct mng_apple_start *);
void MKFrontendTerminal(void);
void MKFrontendGuestReady(void);
#endif
/* Only these wrappers may touch the original HLE input state in Canopy builds. */
int MKSubmit(const struct mng_session_input *,uint64_t now_ns);
void MKClearInput(void);
int MKSetFocus(int);
int MKUpdateLayout(double,double,double);
int MKReadLifecycle(struct mng_apple_lifecycle *);
int MKStart(const struct mng_apple_start *);
void MKGuestEntry(void (*guest)(void));
void MKCopyUID(uint64_t out[2]);
void *MKMetalDevice(void);
void MKInputResetSeat(unsigned player);
void MKInputFocus(int active);
void MKInputTerminal(void);
_Noreturn void MKControllerUnavailable(void);
uint32_t MKControllerSupport(int32_t *out,const int8_t *args);
#endif
