#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// No-JIT experiment 2: libffi closures (what LWJGL callbacks are) from the
/// bundled liblwjgl.dylib builds, in whatever process state the app is in
/// (normally: launched from the Home screen, no debugger). Each step is appended
/// to `logPath` and fsync'd before it runs, so a code-signing kill still leaves
/// the last step on disk. Call off the main thread. Returns YES when every
/// dylib passed; `report` gets the full log.
BOOL VXFFIClosureTestRun(NSString *logPath, NSString *_Nullable *_Nullable report);

NS_ASSUME_NONNULL_END
