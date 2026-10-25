/* Original-source signed-section platform permission probe.
 * Uses the same Apple APIs as the production mapper, not its runtime/loader.
 * No dynamically generated executable memory, game inputs or emulator.
 */
#import <UIKit/UIKit.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach/mach.h>
#include "mach_vm_compat.h"
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "ios_embed.h"

static NSString *failure;
static uintptr_t expected_return;
static unsigned host_calls;
static int check(int condition, NSString *message) {
    if (!condition && !failure) failure = message;
    return condition;
}
static int digest_matches(const void *bytes, size_t length, const char *expected) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    char hex[65];
    CC_SHA256(bytes, (CC_LONG)length, hash);
    for (unsigned i = 0; i < sizeof(hash); ++i) snprintf(hex + i*2, 3, "%02x", hash[i]);
    return strcmp(hex, expected) == 0;
}
static int remap(mach_vm_address_t target, const void *source, size_t length,
                 boolean_t copy, vm_prot_t expected) {
    vm_prot_t current = 0, maximum = 0;
    mach_vm_address_t actual = target;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &actual, length, 0,
        VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
        (mach_vm_address_t)source, copy, &current, &maximum, VM_INHERIT_NONE);
    return check(kr == KERN_SUCCESS && actual == target && current == expected,
        [NSString stringWithFormat:@"remap failed: kr=%d protection=%d expected=%d", kr, current, expected]);
}
static int permission(mach_vm_address_t address, vm_prot_t expected) {
    mach_vm_address_t actual = address;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = mach_vm_region(mach_task_self(), &actual, &size,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object) mach_port_deallocate(mach_task_self(), object);
    return check(kr == KERN_SUCCESS && actual <= address && address-actual < size &&
                 info.protection == expected, @"observed mapped permissions differ");
}
__attribute__((noinline)) static uint64_t host_target(uint64_t a, uint64_t b, uint64_t c, uint64_t d) {
    ++host_calls;
    check((uintptr_t)__builtin_return_address(0) == expected_return, @"host return address differs");
    check(b == 2 && c == 3 && d == 4, @"host entry arguments differ");
    return a + 7;
}

static NSDictionary *probe(void) {
    mach_vm_address_t base = 0;
    mach_vm_size_t total = 0;
    pthread_key_t keys[8];
    unsigned created = 0;
    uint64_t answer = 0, tls_answer = 0, relocated_answer = 0;
    unsigned long nx0 = 0, nw = 0, nx1 = 0;
    const uint8_t *x0 = getsectiondata(&_mh_execute_header, "__TOTKX", "__fixturex0", &nx0);
    const uint8_t *w = getsectiondata(&_mh_execute_header, "__TOTKfixtureW", "__img", &nw);
    const uint8_t *x1 = getsectiondata(&_mh_execute_header, "__TOTKX", "__fixturex1", &nx1);
    if (!check(sysconf(_SC_PAGESIZE) == 0x4000, @"requires 16 KiB Apple pages") ||
        !check(x0 && w && x1 && nx0 == 0x4000 && nw == 0xc000 && nx1 > 0 && !(nx1 % 0x4000), @"section layout differs") ||
        !check(!((uintptr_t)x0 % 0x4000) && !((uintptr_t)w % 0x4000) && !((uintptr_t)x1 % 0x4000), @"section alignment differs") ||
        !check(digest_matches(x0, nx0, ios_embed[0].x0) &&
               digest_matches(w, nw, ios_embed[0].w) &&
               digest_matches(x1, nx1, ios_embed[0].x1), @"embedded hash mismatch")) goto done;
    total = nx0 + nw + nx1;
    if (!check(mach_vm_allocate(mach_task_self(), &base, total, VM_FLAGS_ANYWHERE) == KERN_SUCCESS,
               @"address reservation failed")) goto done;
    if (!remap(base, x0, nx0, FALSE, VM_PROT_READ | VM_PROT_EXECUTE) ||
        !remap(base+nx0, w, nw, TRUE, VM_PROT_READ | VM_PROT_WRITE) ||
        !remap(base+nx0+nw, x1, nx1, FALSE, VM_PROT_READ | VM_PROT_EXECUTE)) goto done;
    for (; created < 8; ++created) {
        if (!check(pthread_key_create(&keys[created], NULL) == 0, @"pthread key allocation failed")) goto done;
        ((uint64_t *)(uintptr_t)(base+0xc000))[created] = (uint64_t)keys[created]*8;
    }
    if (!check(pthread_setspecific(keys[0], (void *)(uintptr_t)host_target) == 0 &&
               pthread_setspecific(keys[1], (void *)(uintptr_t)0x12345678) == 0, @"pthread slot initialization failed")) goto done;
    uintptr_t tsd;
    __asm__ volatile("mrs %0,tpidrro_el0" : "=r"(tsd));
    if (!check(tsd && !(tsd & 7) && ((uintptr_t *)tsd)[keys[0]] == (uintptr_t)host_target &&
               ((uintptr_t *)tsd)[keys[1]] == 0x12345678, @"Darwin TLS layout differs")) goto done;
    /* The fixture declares exactly one known RELATIVE data relocation. This
     * explicit write tests platform permissions, not production relocation. */
    if (!check(*(uint64_t *)(uintptr_t)(base+0x8000) == 0x140, @"relative pointer fixture differs")) goto done;
    *(uint64_t *)(uintptr_t)(base+0x8000) = base+0x140;
    *(uint64_t *)(uintptr_t)(base+0x8008) = 0xabcdef;
    if (!check(*(const uint64_t *)(w+0x4000) == 0x140 &&
               *(const uint64_t *)(w+0x4008) == 0x123456789abcdef0,
               @"data remap did not preserve original signed section")) goto done;
    if (!check(mprotect((void *)(uintptr_t)(base+0x4000), 0x4000, PROT_READ) == 0 &&
               mprotect((void *)(uintptr_t)(base+0xc000), 0x4000, PROT_READ) == 0,
               @"read-only data sealing failed")) goto done;
    if (!permission(base, VM_PROT_READ | VM_PROT_EXECUTE) ||
        !permission(base+0x4000, VM_PROT_READ) ||
        !permission(base+0x8000, VM_PROT_READ | VM_PROT_WRITE) ||
        !permission(base+0xc000, VM_PROT_READ) ||
        !permission(base+0x10000, VM_PROT_READ | VM_PROT_EXECUTE)) goto done;
    expected_return = base+0x118;
    answer = ((uint64_t (*)(uint64_t,uint64_t,uint64_t,uint64_t))(uintptr_t)(base+0x100))(10,2,3,4);
    tls_answer = ((uint64_t (*)(void))(uintptr_t)(base+0x180))();
    relocated_answer = ((uint64_t (*)(uint64_t))(uintptr_t)*(uint64_t *)(uintptr_t)(base+0x8000))(20);
    check(answer == 17 && tls_answer == 0x12345678 && relocated_answer == 27 && host_calls == 1,
          @"native fixture results differ");
done:
    while (created) pthread_key_delete(keys[--created]);
    if (base) mach_vm_deallocate(mach_task_self(), base, total);
    return @{@"status": failure ? @"fail" : @"pass", @"failure": failure ?: @"",
        @"scope": @"original-source embedded-section platform permission probe; not production runtime integration",
        @"answer": @(answer), @"tls_answer": @(tls_answer), @"relocated_answer": @(relocated_answer),
        @"host_calls": @(host_calls), @"external_code_loading": @"not_tested",
        @"production_svc_dispatch": @"not_tested", @"gameplay": @"not_tested",
        @"os": NSProcessInfo.processInfo.operatingSystemVersionString};
}

@interface FixtureDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation FixtureDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    NSDictionary *result = probe();
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [json writeToURL:[documents URLByAppendingPathComponent:@"fixture-result.json"] atomically:YES];
    NSLog(@"FIXTURE_RESULT %@", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(self.window.bounds, 24, 40)];
    label.numberOfLines = 0;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    [controller.view addSubview:label];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(FixtureDelegate.class)); }
}
