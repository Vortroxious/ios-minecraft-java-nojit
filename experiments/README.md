# Experiments

The code used for the measurements in [../JITLESS_RESEARCH.md](../JITLESS_RESEARCH.md). It is reference code, not a buildable project: the iOS parts were written into Voxelium's app target at commit [`5a5043b`](https://github.com/Vortroxious/Voxelium-launcher/tree/5a5043b) and removed after the experiments.

## `Tick.java`: Mac interpreter benchmark

A rough stand-in for a game tick: value noise over four 16×16×384 "chunks", a HashMap of packed block positions, and a sort.

```bash
javac -d . Tick.java
```

```bash
java -cp . Tick 15
```

```bash
java -Xint -cp . Tick 4
```

On an Apple M4 with JDK 26 a steady-state round took about 20 ms with JIT, 29 ms with C1 only, and 242 ms with `-Xint`.

The second Mac benchmark is Minecraft 1.20.1's own data generator, run from the client jar and its libraries (classpath from the version JSON, without LWJGL):

```bash
java -Xint -Xmx2G -cp "<classpath>" net.minecraft.data.Main --all --output out
```

It took 6.2 s with JIT and 73.1 s with `-Xint`.

## `FFIClosureTest.{h,m}`: libffi callbacks without a debugger (iOS)

**What it tests:** whether LWJGL's callbacks, which are libffi closures, work in an iOS app process with no debugger attached.

**How:**
- It `dlopen`s each bundled `liblwjgl.dylib` and calls LWJGL's exported `Java_org_lwjgl_system_libffi_LibFFI_*` wrappers with a NULL `JNIEnv`. That exercises the exact shipped libffi without a JVM.
- It prepares closures with real GLFW signatures and calls them:
  - on the main thread;
  - on a separate thread;
  - through the app's own `glfwSetErrorCallback`.
- It checks a return value, then runs 2,000 closures twice.
- Each step is written to the log with `fsync` before it runs.

**Dependencies:** Voxelium's `JITSupport.h` (debugger and TXM flags), its GLFW header, and a one-line helper in `VXGLFW.m`:

```objc
void VXGLFWRaiseTestError(void) {
    vxError(GLFW_INVALID_VALUE, "libffi callback test");
}
```

**Result on iPhone 15 Pro Max, iOS 27 (TXM), `CS_DEBUGGED=0`:** `ZALITH_FFI_CLOSURE_OK` for LWJGL 3.3.3 and 3.4.1, three runs including one after a reboot. See [../evidence/](../evidence/).

## The `-Xint` switch (planned, not run on the device)

The experiment build had two flag files read by the launcher:

- `logs/jvm-xint`, which added `-Xint` and dropped `-XX:TieredStopAtLevel`;
- `logs/perf-stats`, which turned on JIT-compilation logging and per-10-second frame-time lines from `glfwSwapBuffers`. Each line had average fps, p50/p95/p99/max, the count of frames over 50 ms and over 100 ms, and the thermal state.

The JVM bridge also printed `System.getProperty("java.vm.info")` after `JNI_CreateJavaVM`. Under `-Xint` this reads "interpreted mode", which proves the switch took effect.

The planned protocol and pass/fail criteria (for example ≥ 19 TPS standing on 1.16.5 before even considering a Zero port) are summarised in the report. The device runs were not done: the work stopped because the Mac numbers already showed interpreter-only Java to be far too slow.
