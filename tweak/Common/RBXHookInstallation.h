#pragma once
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif

// Each translation unit owns its installation evidence. A caller must still
// exercise mandatory C-hook behavior; a trampoline alone is not that proof.
static unsigned int RBXHookAttempts, RBXHookFailures;
struct RBXMessageHookRecord { Class target; SEL selector; IMP replacement; };
static struct RBXMessageHookRecord RBXMessageHooks[256];
static unsigned int RBXMessageHookCount;
static inline const void *RBXHookCodePointer(const void *pointer) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(pointer, ptrauth_key_function_pointer);
#else
    return pointer;
#endif
}
static inline void RBXRecordHook(BOOL passed) {
    __atomic_fetch_add(&RBXHookAttempts, 1, __ATOMIC_RELAXED);
    if (!passed) __atomic_fetch_add(&RBXHookFailures, 1, __ATOMIC_RELAXED);
}
static inline BOOL RBXHookInstallationPassed(void) {
    return __atomic_load_n(&RBXHookAttempts, __ATOMIC_RELAXED) > 0 &&
        __atomic_load_n(&RBXHookFailures, __ATOMIC_RELAXED) == 0;
}
static inline void RBXCheckedHookFunction(void *symbol, void *replacement, void **original) {
    if (original) *original = NULL;
    if (!symbol || !replacement || !original) { RBXRecordHook(NO); return; }
    MSHookFunction(symbol, replacement, original);
    RBXRecordHook(*original && RBXHookCodePointer(*original) != RBXHookCodePointer(symbol));
}
static inline void RBXCheckedHookMessage(Class target, SEL selector, IMP replacement, IMP *original) {
    if (original) *original = NULL;
    if (!target || !selector || !replacement || !original || !class_getInstanceMethod(target, selector)) {
        RBXRecordHook(NO); return;
    }
    MSHookMessageEx(target, selector, replacement, original);
    Method method = class_getInstanceMethod(target, selector);
    BOOL passed = *original && method &&
        RBXHookCodePointer((const void *)method_getImplementation(method)) ==
            RBXHookCodePointer((const void *)replacement);
    if (passed && RBXMessageHookCount < 256) {
        RBXMessageHooks[RBXMessageHookCount++] = { target, selector, replacement };
    } else passed = NO;
    RBXRecordHook(passed);
}
// Called only from a serialized installer, for blocking methods which never
// invoke %orig. Preserve interception when UIKit returns a class-cluster subclass
// with its own implementation. Never use this for methods needing trampolines.
static inline void RBXMirrorBlockingHooksToSubclass(Class parent, Class child) {
    unsigned int count = RBXMessageHookCount;
    for (unsigned int i = 0; i < count; i++) {
        struct RBXMessageHookRecord record = RBXMessageHooks[i];
        if (record.target != parent) continue;
        Method method = class_getInstanceMethod(child, record.selector);
        if (method && RBXHookCodePointer((const void *)method_getImplementation(method)) ==
            RBXHookCodePointer((const void *)record.replacement)) continue;
        IMP unused = NULL;
        RBXCheckedHookMessage(child, record.selector, record.replacement, &unused);
    }
}
#define MSHookFunction RBXCheckedHookFunction
#define MSHookMessageEx RBXCheckedHookMessage
