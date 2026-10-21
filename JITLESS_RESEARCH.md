# Can Voxelium run Minecraft without JIT?

Written 2026-10-21 for [Voxelium](https://github.com/Vortroxious/Voxelium-launcher), an iOS launcher for Minecraft: Java Edition. Code references point to Voxelium at commit `5a5043b`. Every claim carries a label:

- **[verified]**: checked in this repository, in a binary we ship, by a measurement in this study, or in a primary source (OpenJDK, Apple, project source code).
- **[likely]**: supported by secondary sources or strong inference, but not tested here.
- **[unknown]**: no good evidence either way.

Numbers in brackets such as [S3] refer to the source list at the end.

## Verdict

**A playable JIT-free Voxelium is not realistic today.** [likely]

- The JVMs we ship cannot start at all without executable memory, even with `-Xint`. [verified]
- The only HotSpot that needs no executable memory is **Zero**, a pure C++ interpreter. OpenJDK's mobile project builds it for iOS and its lead says it is "not enough" for demanding apps [S1][S2]. On the Mac, even HotSpot's *faster* interpreter is **12–15× slower than JIT on Minecraft's own code** (measured below), and Zero is slower still. On the iPhone, the integrated server already logs "Can't keep up!" **with** JIT ([ENGINEERING_LOG.md line 424](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/docs/ENGINEERING_LOG.md?plain=1#L424)). At 12–15× slower, singleplayer would run at about 1–2 ticks per second. [likely]
- AOT compilers (GraalVM native-image, RoboVM, J2ObjC) cannot load mods or Mixin-generated classes at run time. GraalVM's new run-time class loading ("Crema") runs those classes in an interpreter, so it hits the same speed limit. It is also experimental. [verified for the design, unknown for iOS]
- There is no non-debugger way to get JIT on stock iOS 26/27 for an app like this. Apple's EU JIT entitlement is for web browsers only, and Apple refused it to iSH [S9][S10]. [verified]

**What is worth doing:**

1. **A "no-JIT" mode for everything except playing.** Accounts, version downloads, mods, worlds and settings already work without StikDebug. Only the Play button checks for a debugger ([`JVMBridge.m:218`](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/App/Voxelium/Native/JVMBridge.m#L218)). Make that clear in the UI and put the StikDebug setup guide right at the point where Play is refused. This takes about 1–3 days. [verified: the app already starts without a debugger, `launcher.log` in [ENGINEERING_LOG.md line 25](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/docs/ENGINEERING_LOG.md?plain=1#L25)]
2. **One cheap on-device experiment before any big investment:** run 1.20.1 and one old version (for example 1.8.9 or 1.12.2) **with StikDebug attached but `-Xint`**. Since Zero is slower than `-Xint`, that run gives the best case any interpreter-only Voxelium could reach. If it is unplayable, a Zero port is not worth 1–2 months. This takes about half a day.
3. **Don't start a Zero port** unless that experiment surprises us. A proof of concept would take about 4–8 person-weeks (see the table) and would probably only make the launcher's Java tools or very old versions usable as a curiosity.

## 1. Why the current stack needs JIT

**The runtime.** All four bundled JREs (8u472, 17.0.20, 21.0.8, 25.0.4) are AngelAuraMC "OpenJDK 64-Bit Server VM … for bsd-aarch64" builds, with only a `lib/server/libjvm.dylib` and no `zero` or `client` variant. [verified: `release` files and `strings` of each libjvm in `build/runtime/jre*/` of a local Voxelium build]

**HotSpot writes machine code at startup, even with `-Xint`.** The server VM's interpreter is a *template interpreter*: at startup HotSpot assembles it into the code cache from templates, along with stubs (call stubs, method-handle adapters, runtime stubs). With `-Xint` it skips the C1/C2 compilers, but it still has to generate and run that code. [verified: the libjvm strings include "TemplateTable initialization", the `TemplateTable::…` generators and "interpreted mode"; OpenJDK's iOS work switched to Zero because of this, as "iOS does not allow writeable and executable sections" [S3]]

The app says so too: [`JVMBridge.m:216-221`](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/App/Voxelium/Native/JVMBridge.m#L216-L221) refuses to start a JVM unless `CS_DEBUGGED` is set ("HotSpot generates its interpreter at startup, so even 'hello world' needs executable memory"). [verified]

**How Voxelium gets executable memory now:**

- **The debugger.** StikDebug attaches through a pairing file and LocalDevVPN, which sets `CS_DEBUGGED`. That is the only state in which iOS lets an app without Apple's private entitlements map memory as executable. [verified: [`JITSupport.m`](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/App/Voxelium/Native/JITSupport.m) `VXJITDebuggerAttached`; Amethyst README [S6]]
- **iOS 26 and TXM (A15 and later).** The Trusted Execution Monitor enforces code-execution policy below the kernel [S11]. On these devices `mprotect(RX)` on our own pages fails even when debugged. Instead the debugger has to create the code mapping:
  - libjvm runs with `-XX:+MirrorMappedCodeCache` ([`JavaTest.swift:173`](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/App/Voxelium/JavaTest.swift#L173)) and calls `dlsym("DeviceHasTXM")`, which the app exports ([`JITSupport.m:102`](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/App/Voxelium/Native/JITSupport.m#L102)), or reads `XNU_HAS_TXM=1`.
  - It then executes `brk #0x69` ("[JIT26] Requesting %zu MB for JIT mapping").
  - StikDebug's `universal.js` script catches that breakpoint and hands back a 240 MB mirrored mapping (one RW view and one RX view, using `vm_remap`, which libjvm imports).
  - The debugger detaches after that single request (`VXJIT26SetDetachAfterFirstBr`), so the 240 MB must last the whole run.

  [verified: [`JITSupport.m`](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/App/Voxelium/Native/JITSupport.m), [`JVMBridge.m:250-281`](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/App/Voxelium/Native/JVMBridge.m#L250-L281), libjvm strings and imports, [ENGINEERING_LOG.md lines 46-81](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/docs/ENGINEERING_LOG.md?plain=1#L46-L81); StikDebug docs on the TXM script [S7]]
- **Java 8 runs C1 only** (`-XX:TieredStopAtLevel=1`, [`MinecraftLauncher.swift:170`](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/App/Voxelium/MinecraftLauncher.swift#L170)) because of a C2 memory blow-up. That is still a JIT. [verified]

## 2. JIT-free JVM options

| Approach | Runs on iOS arm64? | Needs W+X / JIT? | Mods, Mixin, run-time classes | Speed vs today | Effort | Label |
|---|---|---|---|---|---|---|
| Current HotSpot with `-Xint` | Yes, with a debugger | **Yes**: the template interpreter is generated at startup | Full | ~12–15× slower (Mac, measured) | 0 (an experiment only) | verified |
| **HotSpot Zero** (C++ interpreter) | Yes: built in OpenJDK's mobile repo, the default iOS variant since May 2025 [S1][S3][S4] | No | Full (it is a real JVM) | Slower than `-Xint`; Zero vs JIT is probably 20–50× or worse | 4–8 person-weeks for a PoC | verified (iOS build), likely (speed) |
| GraalVM native-image (closed world) | Via Gluon tooling, not an official GraalVM target [S13] | No | **No** run-time class loading [S12] | Fast for what is compiled in | Not viable: mods and Mixin need it | verified |
| GraalVM native-image + Crema (`-H:+RuntimeClassLoading`) | Unknown on iOS | No for the interpreter; its future JIT ("Ristretto") would need it | Run-time classes are **interpreted** [S14] | Base game AOT, mods and transformed classes interpreted | Months; experimental, with open bugs [S14][S15] | verified (design), unknown (iOS) |
| Leyden AOT cache (JDK 24–26: JEP 483/515/516) | Same HotSpot | **Yes**: it caches loaded classes, profiles and objects, not finished machine code [S16][S17] | Full | Faster startup only | Doesn't remove JIT | verified |
| Leyden AOT *code* (draft JEP 8335368) | Future | Code is generated ahead, but HotSpot still needs the template interpreter and stubs. OpenJDK mobile plans "Zero + AOT methods" [S2] | Full, but only methods compiled ahead | Unknown | Not released; years away for us | unknown |
| OpenJ9 AOT | No iOS port | Its AOT code is relocated into executable memory at run time | Full | — | Not viable | likely |
| RoboVM / MobiVM | Yes (AOT) | No | **Cannot load bytecode at run time** [S18]; Java 7/8 class library | — | Not viable for Minecraft | verified |
| J2ObjC | Yes | No | Source translation only: no jars, no mods | — | Not viable | verified |
| Avian | Abandoned (last release 2015) | Its JIT needs W+X, its interpreter does not | Old class library | — | Not viable | likely |
| CheerpJ in WKWebView | Yes: WebKit's JavaScriptCore has JIT inside Apple's own WebContent process | No for our app (Apple's process does the JIT) | It runs unmodified Minecraft **1.2.5** (the Browsercraft demo, LWJGL 2 + gl4es on WebGL) [S19]; Java 17 is in preview, 21 planned [S20] | Unknown for modern versions; WebGL 2 ≈ GLES 3.0 | Big: proprietary licence, no LWJGL 3/GLFW layer, browser memory limits | verified (demo), unknown (modern MC) |

**Notes on Zero:**

- **Old numbers only.** Published benchmarks are anecdotal or old. A JDK maintainer reports a Minecraft server took "nearly 1 minute" to start on Zero versus "seconds" on the server VM [S5]. A 2023 CHERI/AArch64 port reported the template interpreter 20× faster than its "Zero assembler interpreter" on SciMark. That figure is preliminary and the variant differs from stock Zero [S21]. [likely]
- **It is built as a static library.** OpenJDK mobile's Zero builds a static `libjvm.a` (`make static-libs-image`) [S1]. Voxelium loads `libjvm.dylib` dynamically, so it would need either a dylib build or relinking. [verified for mobile, unknown for a dylib]
- **Java 8 is the hard case.** Old Minecraft versions (≤ 1.16) need Java 8, and no bsd-aarch64 Zero build of JDK 8 exists. Modern Zero lives in JDK 21+. [likely]

## 3. Other things that need executable memory

- **libffi closures, used by LWJGL callbacks: a real risk.**
  - LWJGL's GLFW key and mouse callbacks, its error callback and GL debug callbacks are libffi closures. Minecraft needs them for input. [verified: `liblwjgl.dylib` statically links libffi 3.4.8/3.5.2 ([`scripts/build-lwjgl.sh`](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/scripts/build-lwjgl.sh)) and imports `vm_allocate`, `vm_remap` and `vm_protect`]
  - On Apple arm64, upstream libffi uses a *trampoline table*. It does not write code: it `vm_remap`s a pre-built trampoline page out of the binary's own signed code (`src/closures.c` `ffi_trampoline_table_alloc`; `configure.ac` sets `FFI_EXEC_TRAMPOLINE_TABLE` for `aarch64-apple-*`). [verified in the libffi 3.4.8 source]
  - However, Apple's own libffi patch says "only entire signed executable segment of a dylib may be remapped" on iOS 12+ and Apple-silicon macOS. So Apple ships a separate `libffi-trampolines.dylib` [S22]. Upstream remaps a single page, which may be refused in a process without a debugger. [likely refused, **unknown** until tested]
  - Today every callback runs after `CS_DEBUGGED` is set, so our successful GLFW callback tests prove nothing about a no-JIT process.
  - Fix if needed: Apple's whole-dylib trampoline scheme, or having [`VXGLFW.m`](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/App/Voxelium/Native/VXGLFW.m) call into Java through JNI instead of LWJGL closures. About 1 week. [likely]
- **JNA** (in the vanilla library list) bundles its own libffi and `libjnidispatch`. It has no iOS native, so it already fails to load today. Not a JIT problem. [likely]
- **MobileGlues, ANGLE and Metal.** GLSL → SPIR-V → MSL translation, then Metal compiles to *GPU* code. No CPU executable memory is involved. The only symptom of shader work is the GLSL cache noted in [ENGINEERING_LOG.md line 239](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/docs/ENGINEERING_LOG.md?plain=1#L239). ANGLE's CPU JIT (SwiftShader) isn't built (`autoninja libEGL libGLESv2` only). [likely; no `mprotect` PROT_EXEC path was found, but this was not traced exhaustively]
- **Mixin, ASM, lambdas, hidden classes and method handles.** These produce *bytecode*, which is data for whatever interpreter or JIT is running. They need no native code beyond what the JVM itself generates: on the server VM that is the method-handle adapter stubs (generated, so they need W+X), while Zero has C++ equivalents. [verified for bytecode; likely for Zero's method-handle support]

## 4. iOS rules and what other projects do

**Apple's rules:**

- Without a debugger, a sideloaded app cannot create executable memory. JIT needs `dynamic-codesigning` (Apple's own apps) or the browser-engine entitlements. [verified: Amethyst README [S6]; PojavLauncher FAQ [S8]]
- **EU (DMA).** BrowserEngineKit allows JIT only in a browser's web-content extension, for developers established in the EU, on iOS 17.4+ [S9]. iSH asked Apple for JIT access for a non-browser app and was refused: "does not fall in scope of article 6(7) DMA" (Oct 2024) [S10]. Alternative marketplaces don't change the entitlement rules. [verified]
- **A paid developer account** gives `get-task-allow`, so you *can* debug your own app, but you still need a debugger attached. There is no "allow JIT" entitlement on iOS for third parties. [verified]
- **TXM (A15+, iOS 26+).** Debugger attach alone is not enough; a script has to bless the memory [S7]. iOS 26.4 reportedly broke the offline/airplane-mode trick and StikDebug for some users [S23]. [likely] The route we depend on is getting narrower, which is an argument for the "no-JIT mode for everything except Play" above.

**Other projects:**

- **Amethyst / PojavLauncher iOS:** no no-JIT mode. They require JIT "to provide usable speeds" and list AltStore, SideStore, StikDebug, TrollStore, Jitterbug and jailbreaks [S6][S8]. [verified; no issue proposing Zero was found, so that part is unknown]
- **UTM SE (App Store):** QEMU's threaded TCG interpreter. Its developers call it the "slow edition", fine for old operating systems, poor for modern ones [S24]. [verified]
- **PPSSPP (App Store, 2024):** no JIT. Its IR interpreter runs most PSP games at full speed, because a 333 MHz PSP is tiny next to an A17 [S25]. [verified] Minecraft Java is the opposite case: it was written for desktop CPUs *with* JIT.
- **iSH:** its interpreter is "5–100× slower than native code"; a JIT prototype gave "2–5×" wins [S10]. That is a useful reference point for interpreted code on an iPhone. [verified]

## 5. Measurements (Mac only)

- **Setup:** Apple M4 (16 GB), macOS 27.0, Oracle JDK 26 (build 26+35-2893). Scratch files only, not in the repo.
- **What was compared:** default (C1+C2 JIT) against `-Xint`, the template interpreter, which is still *faster* than Zero.

| Workload | JIT | C1 only | `-Xint` | Slowdown |
|---|---|---|---|---|
| Minecraft 1.20.1 data generator (`net.minecraft.data.Main --all`: bootstrap, DataFixerUpper, codecs, 9,172 files), wall time | 6.2 s | — | 73.1 s | **11.8×** |
| Same, "All providers took" (the hot part) | 2.18 s | — | 32.7 s | **15×** |
| Tick-like loop (noise over 4 chunks, a HashMap of packed positions, a sort), steady-state round | ~20 ms | ~29 ms | ~242 ms | **12×** |

How to reproduce:

```bash
java -Xint -Xmx2G -cp "<1.20.1 classpath from the version JSON, without LWJGL>" net.minecraft.data.Main --all --output out
```

Run it once without `-Xint` for the JIT figure. The tick benchmark is a small `Tick.java` of value noise plus HashMap and sort work, run with `java -cp . Tick 15` and `java -Xint -cp . Tick 4`.

**What that means on the phone** [likely; an extrapolation, not a measurement]:

- The A17 Pro is roughly 1.2–1.4× slower single-threaded than the M4 (Geekbench-class comparisons).
- With JIT, the iPhone already needed 25.8 s for spawn preparation and logged "Can't keep up!" ([ENGINEERING_LOG.md](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/docs/ENGINEERING_LOG.md?plain=1) lines [240](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/docs/ENGINEERING_LOG.md?plain=1#L240) and [424](https://github.com/Vortroxious/Voxelium-launcher/blob/5a5043b/docs/ENGINEERING_LOG.md?plain=1#L424)).
- `-Xint` would make spawn preparation about 5–8 minutes and the server tick roughly 1–2 TPS instead of 20. Client-side work (chunk meshing, entities, the GUI) would slow down by the same factor.
- Zero would be worse again.

That fails the "playable" bar this study set: title screen in under 3 minutes, 20 TPS and at least 20 FPS in a 1.20.1 world.

## 6. Risks and dependencies

- **Apple can close the debugger route.** iOS 26.4 already narrowed it [S23]. A future TXM change could break JIT26 entirely, and the only fallback would then be Zero's slowness.
- **Zero porting risks:** OpenJDK mobile is a side project (static libs, JDK 25+); there is no JDK 8 Zero; libffi closures on iOS are unverified; AngelAuraMC's patches (the iOS file-system and memory tweaks) would have to be re-applied to a Zero build.
- **Crema/GraalVM risks:** experimental, no iOS target, and it would mean replacing the whole runtime and launch path.
- **Licences:** OpenJDK Zero is GPLv2+CE (fine). GraalVM CE is GPLv2+CE (fine). CheerpJ is proprietary (needs a licence).

## 7. Recommendation and effort

| Option | Effort | Expected result |
|---|---|---|
| Clear no-JIT mode (everything but Play) and better StikDebug onboarding at the Play button | 1–3 days | Real UX gain now |
| On-device `-Xint` benchmark (a hidden switch such as a `logs/`-file flag, like the existing `lwjgl-debug`) | ½ day plus one device session | Decides whether any interpreter path is worth pursuing |
| libffi closure test without a debugger (a tiny ObjC test calling `ffi_closure_alloc` + `ffi_prep_closure_loc` in a normal launch) | ½ day | Tells whether LWJGL callbacks would survive without JIT |
| Zero PoC (JDK 21/25 Zero dylib for iOS, hello world → LWJGL → title screen) | 4–8 person-weeks | Probably runs, too slow to play [likely] |
| GraalVM Crema or CheerpJ path | Months | Not recommended |

**Next step:** ship the clearer no-JIT mode, and run the two half-day experiments (`-Xint` on device, libffi closure without a debugger). Revisit Zero only if `-Xint` on the A17 Pro reaches at least about 10 TPS on an old version.

## 8. Experiment results (2026-10-21)

Both experiments used a separate diagnostic build ("Voxelium Exp", bundle ID `io.github.voxelium.launcher.nojitexp`) from the local branch `exp/nojit-experiments`. That build was not released.

**Experiment 2, libffi callbacks without a debugger: PASS.** [verified]
- **Setup:** iPhone 15 Pro Max, iOS 27, TXM device. Launched from the Home screen with `CS_DEBUGGED=0`. Three runs, the last after a reboot.
- **Method:** the test called the shipped `liblwjgl.dylib`'s own libffi exports, for both LWJGL 3.3.3 and 3.4.1.
- **Allocation works:**
  - `ffi_closure_alloc` succeeded each time;
  - its trampoline page is mapped `r-x` (a remap of the dylib's signed trampoline page).
- **Calls work.** These closures ran correctly:
  - `GLFWkeyfun` on the main thread;
  - `GLFWcursorposfun`, with doubles, on a separate thread;
  - `GLFWerrorfun` through VXGLFW's real `glfwSetErrorCallback` path;
  - an `int(int,int)` return value.
- **Stress test works:** 2,000 closures over 2 trampoline pages, freed and allocated again, with no wrong results.
- **Result:** `ZALITH_FFI_CLOSURE_OK` for both builds on every run.
- **What this changes:** the concern in section 3, based on Apple's whole-dylib remap patch [S22], does not apply here. LWJGL callbacks are **not** a blocker for a JIT-free runtime.
- **Not covered:** the JNI upcall into Java, because no JVM can start without a debugger.

**Experiment 1, `-Xint` on the device: not run.** After Experiment 2 the maintainer decided to stop the JIT-free work. The Mac measurements in section 5 already show interpreter-only execution 12–15× slower than JIT. Zero would be slower still, so the measurement was not worth the device time.

**Decision:** no Zero port and no further JIT-free work. StikDebug stays required to play. The useful follow-up is the UX work in the recommendation:
- everything except Play works without JIT;
- guided StikDebug setup and clear messages at the Play gate.

## Sources

All accessed 2026-10-21.

- [S1] OpenJDK mobile-dev, "hotspot Zero for iOS" (May 2025, quoting Johan Vos, Dec 2024): https://mail.openjdk.org/pipermail/mobile-dev/2025-May/000944.html
- [S2] InfoQ, "Java on iOS" (Ben Evans, Nov 2025): https://www.infoq.com/news/2025/11/java-on-ios
- [S3] RFR 8357119, "Make Zero the default … variant of HotSpot for iOS": https://mail.openjdk.org/pipermail/mobile-dev/2025-May/000952.html
- [S4] Integrated 8357119 (openjdk/mobile, May 26, 2025): https://mail.openjdk.org/pipermail/mobile-dev/2025-May/000970.html
- [S5] jdk-dev, JEP 501 discussion (Julian Waters, Nov 2024), Zero vs server VM on Minecraft server startup: https://mail.openjdk.org/pipermail/jdk-dev/2024-November/009652.html
- [S6] Amethyst-iOS README (JIT section and table): https://github.com/AngelAuraMC/Amethyst-iOS
- [S7] StikDebug / StikJIT repository and docs (TXM scripts, `get-task-allow`, LocalDevVPN, DDI): https://github.com/StephenDev0/StikDebug, https://github.com/StikDebug/StikJIT
- [S8] PojavLauncher FAQ, "iOS and JIT": https://pojavlauncher.app/wiki/faq/ios/JIT.html
- [S9] Apple, BrowserEngineKit documentation: https://developer.apple.com/documentation/browserenginekit
- [S10] iSH blog, "iSH, JIT, and EU" (Oct 16, 2024): https://ish.app/blog/ish-jit-and-eu
- [S11] Apple Platform Security, Memory Integrity Enforcement / SPTM and TXM: https://support.apple.com/guide/security/sec8b776536b
- [S12] graalvm-dev, dynamic class loading on SubstrateVM (2020): https://oss.oracle.com/pipermail/graalvm-dev/2020-April/000047.html
- [S13] OpenJDK mobile, "rebooting OpenJDK mobile" (2019, Gluon's iOS native images): https://mail.openjdk.org/pipermail/mobile-dev/2019-June/000585.html
- [S14] oracle/graal issue #11327, "Project Crema: Open World for Native Image": https://github.com/oracle/graal/issues/11327
- [S15] GraalVM 25.1 release notes (`-H:+RuntimeClassLoading`, "early version"): https://www.graalvm.org/release-notes/25.1/; open bug: https://github.com/oracle/graal/issues/14541
- [S16] JEP 516, AOT Object Caching with Any GC (JDK 26): https://openjdk.org/jeps/516
- [S17] Draft JEP 8335368, Ahead-of-Time Code Compilation: https://openjdk.org/jeps/8335368
- [S18] ADTmag on RoboVM ("can not load bytecode at runtime"): https://adtmag.com/articles/2015/04/06/java-to-ios.aspx
- [S19] Leaning Technologies, Browsercraft (Minecraft 1.2.5 on CheerpJ): https://labs.leaningtech.com/showcase/browsercraft
- [S20] CheerpJ roadmap / 4.1 release: https://cheerpj.com/our-roadmap-for-modern-java-in-the-browser/, https://labs.leaningtech.com/blog/cheerpj-4.1.html
- [S21] Anisbet, CHERI JDK port slides (2023), template interpreter vs Zero on AArch64: https://www.dcs.gla.ac.uk/~jsinger/cheritech23_slides/anisbet_cheritech.pdf
- [S22] Apple libffi patch "arm64: use a dedicated dylib for trampolines" (J. Huddleston Sequoia, 2020), conda mirror: https://decoder-genetics.wustl.edu/software/conda/pkgs/libffi-3.4.2-h7f98852_5/info/recipe/0001-arm64-use-a-dedicated-dylib-for-trampolines-so-it-ca.patch
- [S23] PiunikaWeb, "iOS 26.4 may break JIT for sideloaded apps" (Mar 26, 2026): https://piunikaweb.com/2026/03/26/ios-26-4-may-break-jit-for-sideloaded-apps/
- [S24] UTM iOS installation docs (UTM SE): https://docs.getutm.app/installation/ios
- [S25] PPSSPP, "Live on App Store" and iOS support notes: https://www.ppsspp.org/news/live-on-app-store/, https://ppsspp.org/docs/reference/ios-support
- libffi 3.4.8 release source (https://github.com/libffi/libffi/releases/tag/v3.4.8): `src/closures.c`, `configure.ac`, `darwin_ios/include/fficonfig_arm64.h`.
