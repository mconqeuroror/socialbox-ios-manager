#if defined(__arm64__)
.text
.p2align 2
.globl _LBXScopedLookup
_LBXScopedLookup:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _objc_msgSend
.globl _LBXScopeReturn
_LBXScopeReturn:
    ldp x29, x30, [sp], #16
    ret
#elif defined(__x86_64__)
.text
.p2align 4
.globl _LBXScopedLookup
_LBXScopedLookup:
    pushq %rbp
    movq %rsp, %rbp
    callq _objc_msgSend
.globl _LBXScopeReturn
_LBXScopeReturn:
    popq %rbp
    retq
#else
#error Unsupported test architecture
#endif
