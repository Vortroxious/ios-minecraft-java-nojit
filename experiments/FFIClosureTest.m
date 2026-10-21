// No-JIT experiment 2: do libffi closures work without a debugger?
//
// LWJGL callbacks (GLFW key/mouse/cursor/error, GL debug) are libffi closures. On
// iOS arm64 libffi is built with FFI_EXEC_TRAMPOLINE_TABLE: ffi_closure_alloc
// vm_remaps a prebuilt trampoline page from liblwjgl.dylib's own code instead of
// writing code. This test drives the exact shipped binaries through their exported
// LWJGL JNI wrappers (Java_org_lwjgl_system_libffi_LibFFI_*), which ignore JNIEnv,
// so no JVM is needed (none can start without a debugger anyway).
//
// Written for Voxelium's App/Voxelium/Native/ (it uses JITSupport.h and the app's
// GLFW implementation; VXGLFWRaiseTestError is a one-line helper added to VXGLFW.m
// that calls its internal vxError(GLFW_INVALID_VALUE, "libffi callback test")).

#import "FFIClosureTest.h"
#import "JITSupport.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <unistd.h>
#define GLFW_INCLUDE_NONE
#include "glfw/GLFW/glfw3.h"

void VXGLFWRaiseTestError(void);  // VXGLFW.m

typedef int32_t (*PrepCif)(void *env, void *cls, int64_t cif, int32_t abi, int32_t nargs, int64_t rtype, int64_t atypes);
typedef int64_t (*ClosureAlloc)(void *env, void *cls, int64_t size, int64_t codeAddress);
typedef void (*ClosureFree)(void *env, void *cls, int64_t writable);
typedef int32_t (*PrepClosureLoc)(void *env, void *cls, int64_t closure, int64_t cif, int64_t fun, int64_t userData, int64_t codeloc);
typedef int64_t (*TypeAddress)(void *env, void *cls);
typedef int32_t (*DefaultABI)(void *env, void *cls);

// Larger than ffi_cif / ffi_closure on arm64 (40 bytes each); libffi only needs at least that.
enum { kCifSize = 128, kClosureSize = 128, kStressCount = 2000 };

typedef struct {
    int calls;
    int64_t i[5];
    double d[2];
    char text[64];
    void *userData;
} Record;

static int gLogFd = -1;
static NSMutableString *gReport;

static void say(const char *fmt, ...) __printflike(1, 2);
static void say(const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    [gReport appendFormat:@"%s\n", line];
    if (gLogFd >= 0) {
        dprintf(gLogFd, "%s\n", line);
        fsync(gLogFd);
    }
    NSLog(@"[FFITEST] %s", line);
}

static void regionInfo(const char *what, void *addr) {
    vm_address_t a = (vm_address_t)addr;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (kr != KERN_SUCCESS) { say("  %s %p: vm_region_64 failed %d", what, addr, kr); return; }
    say("  %s %p: region 0x%lx+0x%lx prot %c%c%c max %c%c%c shared=%d", what, addr, (unsigned long)a, (unsigned long)size,
        info.protection & VM_PROT_READ ? 'r' : '-', info.protection & VM_PROT_WRITE ? 'w' : '-', info.protection & VM_PROT_EXECUTE ? 'x' : '-',
        info.max_protection & VM_PROT_READ ? 'r' : '-', info.max_protection & VM_PROT_WRITE ? 'w' : '-', info.max_protection & VM_PROT_EXECUTE ? 'x' : '-',
        info.shared);
}

#pragma mark - Closure handlers (libffi signature: cif, ret, args, user_data)

static void keyHandler(void *cif, void *ret, void **args, void *ud) {
    Record *r = ud;
    r->calls++;
    r->i[0] = (int64_t)(uintptr_t)*(void **)args[0];
    for (int k = 1; k <= 4; k++) r->i[k] = *(int *)args[k];
    r->userData = ud;
}

static void cursorHandler(void *cif, void *ret, void **args, void *ud) {
    Record *r = ud;
    r->calls++;
    r->i[0] = (int64_t)(uintptr_t)*(void **)args[0];
    r->d[0] = *(double *)args[1];
    r->d[1] = *(double *)args[2];
    r->userData = ud;
}

static void errorHandler(void *cif, void *ret, void **args, void *ud) {
    Record *r = ud;
    r->calls++;
    r->i[0] = *(int *)args[0];
    const char *s = *(const char **)args[1];
    snprintf(r->text, sizeof(r->text), "%s", s ? s : "(null)");
    r->userData = ud;
}

static void addHandler(void *cif, void *ret, void **args, void *ud) {
    Record *r = ud;
    r->calls++;
    // Integral returns narrower than a register are widened to ffi_arg (64-bit here).
    *(int64_t *)ret = (int64_t)(*(int *)args[0] * 1000 + *(int *)args[1]);
}

static void stressHandler(void *cif, void *ret, void **args, void *ud) {
    *(int64_t *)ret = (int64_t)(*(int *)args[0] + (int)(intptr_t)ud);
}

typedef void (*CursorFn)(void *, double, double);
typedef struct { CursorFn fn; } CursorCall;

static void *cursorThread(void *p) {
    ((CursorCall *)p)->fn((void *)0xC0FFEE, 12.5, -7.25);
    return NULL;
}

#pragma mark - One liblwjgl.dylib

static BOOL testLibrary(NSString *path, NSString *name) {
    say("== %s (%s)", name.UTF8String, path.UTF8String);
    say("step 1: dlopen");
    void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!h) { say("ZALITH_FFI_CLOSURE_FAIL %s step=1 reason=dlopen: %s", name.UTF8String, dlerror()); return NO; }

    say("step 2: resolve LibFFI JNI exports");
#define SYM(type, var, sym) type var = (type)dlsym(h, "Java_org_lwjgl_system_libffi_LibFFI_" sym)
    SYM(PrepCif, prepCif, "nffi_1prep_1cif");
    SYM(ClosureAlloc, closureAlloc, "nffi_1closure_1alloc");
    SYM(ClosureFree, closureFree, "nffi_1closure_1free");
    SYM(PrepClosureLoc, prepClosure, "nffi_1prep_1closure_1loc");
    SYM(TypeAddress, typeSint32, "nffi_1type_1sint32");
    SYM(TypeAddress, typeDouble, "nffi_1type_1double");
    SYM(TypeAddress, typePointer, "nffi_1type_1pointer");
    SYM(TypeAddress, typeVoid, "nffi_1type_1void");
    SYM(DefaultABI, defaultABI, "FFI_1DEFAULT_1ABI");
#undef SYM
    if (!prepCif || !closureAlloc || !closureFree || !prepClosure || !typeSint32 || !typeDouble || !typePointer || !typeVoid || !defaultABI) {
        say("ZALITH_FFI_CLOSURE_FAIL %s step=2 reason=missing export", name.UTF8String);
        return NO;
    }
    // Both LWJGL builds share one install name; make sure this dlopen gave this file.
    Dl_info where;
    const char *image = dladdr((void *)prepCif, &where) && where.dli_fname ? where.dli_fname : "?";
    say("  exports come from %s", image);
    char realImage[PATH_MAX] = "", realPath[PATH_MAX] = "";
    realpath(image, realImage);
    realpath(path.fileSystemRepresentation, realPath);
    if (strcmp(realImage, realPath) != 0) {
        say("ZALITH_FFI_CLOSURE_SKIP %s reason=dyld returned an already loaded image; run the test again after relaunching", name.UTF8String);
        return NO;
    }
    int64_t tInt = typeSint32(NULL, NULL), tDouble = typeDouble(NULL, NULL), tPtr = typePointer(NULL, NULL), tVoid = typeVoid(NULL, NULL);
    int32_t abi = defaultABI(NULL, NULL);
    say("  abi %d, types int %#llx double %#llx ptr %#llx void %#llx", abi, tInt, tDouble, tPtr, tVoid);

    say("step 3: prep CIFs (GLFWkeyfun, GLFWcursorposfun, GLFWerrorfun, int(int,int), int(int))");
    static uint8_t cifKey[kCifSize], cifCursor[kCifSize], cifError[kCifSize], cifAdd[kCifSize], cifStress[kCifSize];
    int64_t keyTypes[] = { tPtr, tInt, tInt, tInt, tInt }, cursorTypes[] = { tPtr, tDouble, tDouble },
            errorTypes[] = { tInt, tPtr }, addTypes[] = { tInt, tInt }, stressTypes[] = { tInt };
    int32_t rc[5] = {
        prepCif(NULL, NULL, (int64_t)(uintptr_t)cifKey, abi, 5, tVoid, (int64_t)(uintptr_t)keyTypes),
        prepCif(NULL, NULL, (int64_t)(uintptr_t)cifCursor, abi, 3, tVoid, (int64_t)(uintptr_t)cursorTypes),
        prepCif(NULL, NULL, (int64_t)(uintptr_t)cifError, abi, 2, tVoid, (int64_t)(uintptr_t)errorTypes),
        prepCif(NULL, NULL, (int64_t)(uintptr_t)cifAdd, abi, 2, tInt, (int64_t)(uintptr_t)addTypes),
        prepCif(NULL, NULL, (int64_t)(uintptr_t)cifStress, abi, 1, tInt, (int64_t)(uintptr_t)stressTypes),
    };
    for (int k = 0; k < 5; k++) if (rc[k] != 0) {
        say("ZALITH_FFI_CLOSURE_FAIL %s step=3 reason=ffi_prep_cif #%d returned %d", name.UTF8String, k, rc[k]);
        return NO;
    }

    // step 4-5: one closure per signature.
    struct { const char *what; uint8_t *cif; void *fun; Record rec; int64_t writable; void *code; } c[4] = {
        { "GLFWkeyfun", cifKey, keyHandler }, { "GLFWcursorposfun", cifCursor, cursorHandler },
        { "GLFWerrorfun", cifError, errorHandler }, { "int(int,int)", cifAdd, addHandler },
    };
    for (int k = 0; k < 4; k++) {
        say("step 4.%d: ffi_closure_alloc for %s", k, c[k].what);
        c[k].writable = closureAlloc(NULL, NULL, kClosureSize, (int64_t)(uintptr_t)&c[k].code);
        say("  writable %#llx code %p", c[k].writable, c[k].code);
        if (!c[k].writable || !c[k].code) {
            say("ZALITH_FFI_CLOSURE_FAIL %s step=4 reason=ffi_closure_alloc returned NULL (vm_remap/vm_protect refused)", name.UTF8String);
            return NO;
        }
        regionInfo("trampoline", c[k].code);
        say("step 5.%d: ffi_prep_closure_loc", k);
        int32_t r = prepClosure(NULL, NULL, c[k].writable, (int64_t)(uintptr_t)c[k].cif, (int64_t)(uintptr_t)c[k].fun,
                                (int64_t)(uintptr_t)&c[k].rec, (int64_t)(uintptr_t)c[k].code);
        if (r != 0) { say("ZALITH_FFI_CLOSURE_FAIL %s step=5 reason=ffi_prep_closure_loc returned %d", name.UTF8String, r); return NO; }
    }
    BOOL ok = YES;

    say("step 6: call GLFWkeyfun closure on the main thread (about to execute the trampoline)");
    void (*keyFn)(void *, int, int, int, int) = c[0].code;
    dispatch_sync(dispatch_get_main_queue(), ^{ keyFn((void *)0x1234, 65, 30, 1, 2); });
    Record *k0 = &c[0].rec;
    BOOL keyOK = k0->calls == 1 && k0->i[0] == 0x1234 && k0->i[1] == 65 && k0->i[2] == 30 && k0->i[3] == 1 && k0->i[4] == 2 && k0->userData == k0;
    say("  %s: calls %d args %#llx %lld %lld %lld %lld", keyOK ? "ok" : "WRONG", k0->calls, k0->i[0], k0->i[1], k0->i[2], k0->i[3], k0->i[4]);
    ok &= keyOK;

    say("step 7: call GLFWcursorposfun closure on a new pthread (as LWJGL callbacks run on the JVM thread)");
    CursorCall call = { (CursorFn)c[1].code };
    pthread_t t;
    pthread_create(&t, NULL, cursorThread, &call);
    pthread_join(t, NULL);
    Record *k1 = &c[1].rec;
    BOOL cursorOK = k1->calls == 1 && k1->i[0] == 0xC0FFEE && k1->d[0] == 12.5 && k1->d[1] == -7.25;
    say("  %s: calls %d args %#llx %.2f %.2f", cursorOK ? "ok" : "WRONG", k1->calls, k1->i[0], k1->d[0], k1->d[1]);
    ok &= cursorOK;

    say("step 8: GLFWerrorfun closure through VXGLFW (glfwSetErrorCallback + a test error)");
    GLFWerrorfun previous = glfwSetErrorCallback((GLFWerrorfun)c[2].code);
    VXGLFWRaiseTestError();
    glfwSetErrorCallback(previous);
    Record *k2 = &c[2].rec;
    BOOL errorOK = k2->calls == 1 && k2->i[0] == GLFW_INVALID_VALUE && strcmp(k2->text, "libffi callback test") == 0;
    say("  %s: calls %d code %#llx text \"%s\"", errorOK ? "ok" : "WRONG", k2->calls, k2->i[0], k2->text);
    ok &= errorOK;

    say("step 9: int(int,int) closure return value");
    int (*addFn)(int, int) = c[3].code;
    int sum = addFn(3, 4);
    BOOL addOK = sum == 3004 && c[3].rec.calls == 1;
    say("  %s: returned %d", addOK ? "ok" : "WRONG", sum);
    ok &= addOK;

    for (int round = 0; round < 2; round++) {
        say("step 10.%d: allocate %d closures (more than one trampoline table), call every 97th, free all", round, kStressCount);
        static int64_t writable[kStressCount];
        static void *code[kStressCount];
        NSMutableSet<NSNumber *> *pages = [NSMutableSet set];
        size_t page = (size_t)getpagesize();
        int allocated = 0;
        for (int i = 0; i < kStressCount; i++) {
            writable[i] = closureAlloc(NULL, NULL, kClosureSize, (int64_t)(uintptr_t)&code[i]);
            if (!writable[i]) break;
            if (prepClosure(NULL, NULL, writable[i], (int64_t)(uintptr_t)cifStress, (int64_t)(uintptr_t)stressHandler,
                            (int64_t)i, (int64_t)(uintptr_t)code[i]) != 0) { closureFree(NULL, NULL, writable[i]); break; }
            [pages addObject:@((uintptr_t)code[i] & ~(uintptr_t)(page - 1))];
            allocated++;
        }
        say("  allocated %d on %lu trampoline pages", allocated, (unsigned long)pages.count);
        int called = 0, wrong = 0;
        for (int i = 0; i < allocated; i += 97) {
            int (*fn)(int) = code[i];
            if (fn(10) != 10 + i) wrong++;
            called++;
        }
        if (allocated > 0) { int (*last)(int) = code[allocated - 1]; called++; if (last(10) != 10 + allocated - 1) wrong++; }
        for (int i = 0; i < allocated; i++) closureFree(NULL, NULL, writable[i]);
        BOOL stressOK = allocated == kStressCount && wrong == 0 && pages.count > 1;
        say("  %s: called %d, wrong %d, freed %d", stressOK ? "ok" : "WRONG", called, wrong, allocated);
        ok &= stressOK;
    }

    for (int k = 0; k < 4; k++) closureFree(NULL, NULL, c[k].writable);
    say("%s %s", ok ? "ZALITH_FFI_CLOSURE_OK" : "ZALITH_FFI_CLOSURE_FAIL", name.UTF8String);
    return ok;
}

BOOL VXFFIClosureTestRun(NSString *logPath, NSString **report) {
    gReport = [NSMutableString string];
    gLogFd = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    unsigned int flags = VXJITGetFlags();
    say("libffi closure test, %s", [NSDate.date descriptionWithLocale:nil].UTF8String);
    say("CS_DEBUGGED=%d debuggerNow=%d JIT flags=0x%X (iOS26=%d mirrored=%d TXM=%d) page=%d",
        VXJITDebuggerAttached(), VXJITDebuggerStillAttached(), flags, !!(flags & VXJITFlagIOS26),
        !!(flags & VXJITFlagForceMirrored), !!(flags & VXJITFlagHasTXM), getpagesize());
    NSString *java = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"java"];
    BOOL ok = YES;
    for (NSString *dir in @[ @"lwjgl", @"lwjgl-3.4.1" ]) {
        NSString *path = [[java stringByAppendingPathComponent:dir] stringByAppendingPathComponent:@"liblwjgl.dylib"];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) { say("ZALITH_FFI_CLOSURE_FAIL %s reason=missing", dir.UTF8String); ok = NO; continue; }
        ok &= testLibrary(path, dir);
    }
    say("%s", ok ? "RESULT: all closures worked" : "RESULT: FAILED (see steps above)");
    if (gLogFd >= 0) close(gLogFd);
    gLogFd = -1;
    if (report) *report = [gReport copy];
    return ok;
}
