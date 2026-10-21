# Minecraft: Java Edition on iOS without JIT

Can an iOS launcher run Minecraft: Java Edition without JIT, that is, without StikDebug, a debugger, LocalDevVPN or a pairing file? This repository is the research done for [Voxelium](https://github.com/Vortroxious/Voxelium-launcher) in October 2026. It is shared so others can check it, build on it, or pick the idea up again if things change.

**Short answer: not today.**
- **The stock runtime needs JIT to start.** HotSpot, the Java VM every iOS launcher uses, generates machine code at startup, even with `-Xint`.
- **The only JIT-free JVM is too slow.** That is HotSpot Zero, and it is slower than `-Xint`. On a Mac, `-Xint` alone made Minecraft's own code 12–15× slower than with JIT, and the iPhone already struggles at full JIT speed.
- **Compiling ahead of time can't load mods.** GraalVM native-image, RoboVM and J2ObjC can't load mods or Mixin classes at run time.
- **Apple offers no other way in.** There is no non-debugger JIT for this kind of app on stock iOS 26/27.

**One thing that does work:** LWJGL's callbacks (libffi closures) work with **no debugger attached** on iOS 27 with TXM. That was tested on an iPhone 15 Pro Max. So if a fast enough JIT-free Java runtime ever appears, callbacks are not the blocker.

## Contents

- [`JITLESS_RESEARCH.md`](JITLESS_RESEARCH.md) is the full report. It covers:
  - the verdict;
  - why the stack needs JIT;
  - every option looked at, with each claim labelled verified, likely or unknown;
  - the measurements and the experiment results;
  - 25 sources.
- [`experiments/`](experiments/) holds the benchmark and the iOS callback test code, with notes on how they were run.
- [`evidence/`](evidence/) holds the raw device log of the callback test.

## What would change the answer

- **OpenJDK's mobile project** (Zero on iOS) adding ahead-of-time compiled methods from Project Leyden, so most code runs as native code instead of being interpreted.
- **GraalVM's "Crema"** (run-time class loading in native images) maturing and getting a fast enough interpreter or an iOS-compatible compilation path.
- **Apple allowing JIT** for non-browser apps, which it currently refuses even in the EU.

If you try one of these, the report's section 7 has the experiments and pass/fail bars to start from.

## Licence

- **Text** (README, report, notes): [CC BY 4.0](LICENSE).
- **Code** in `experiments/`: [GPL-3.0](LICENSE-CODE), like Voxelium.

Minecraft is a trademark of Mojang/Microsoft. This project is not affiliated with them.
