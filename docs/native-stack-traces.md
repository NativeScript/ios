# Native stack traces

The runtime prints a native stack trace when an assertion fails
(`====== Assertion failed ======`), when it logs an uncaught JavaScript error
(`Native stack trace:`), and on a fatal Node-API error. This page explains how
to read those traces and how to turn them into exact function names, file names
and line numbers.

## What a trace looks like

```
Native stack trace:
1   NativeScript                          0x104ca2088 0x104a00000 + 2760840 v8::CppHeap::CollectGarbageInYoungGenerationForTesting(cppgc::EmbedderStackState) + 8048
2   NativeScript                          0x104b1ee7c 0x104a00000 + 1175164 tns::ModuleInternal::RunModule(v8::Isolate*, std::__1::basic_string<char, ...>) + 92
3   MyApp                                 0x102f1a2b4 0x102f00000 + 107188 main + 120
Binary images:
0x104a00000 NativeScript arm64 <03DD4E84-EE0C-3280-AF5D-5CC4087BB5A5> /private/var/containers/Bundle/Application/.../MyApp.app/Frameworks/NativeScript.framework/NativeScript
0x102f00000 MyApp arm64 <...> /private/var/containers/Bundle/Application/.../MyApp.app/MyApp
```

(The `NativeScript` frames are real offsets in the
`v9.1.0-next.2026-11-05-42101299477` build, so the commands below can be tried
against that release's dSYM.)

Each frame is `index  image  address  load-address + offset  symbol + offset`,
the same layout as an Apple crash report. The `Binary images:` list at the end
has one line per image that appears in the trace: its load address, name,
architecture, UUID and path.

## Why the function names can be wrong

Release builds of `NativeScript.framework` ship without internal (non-exported)
symbols, which saves about 2.7 MB per app. The name printed after the offset is
the nearest *exported* symbol at or before the address. For the runtime's and
V8's internal functions, that is a different function. In the first frame
above, the real function is `v8::internal::CppHeap::CollectGarbage`, not the
`...ForTesting` function the log names. A large symbol offset (thousands of
bytes) is a strong hint that the name is wrong.

The image offset (`0x104a00000 + 2760840`) is always exact. Use it with the
framework's dSYM to get the real name.

Debug builds of the runtime (local development, the test suite) keep every
symbol, so their names are exact.

## Getting the dSYM

The dSYM must come from the same build as the framework in the app. Every build
has its own UUID, shown in the `Binary images:` line.

- **From the release.** Each GitHub release of
  [NativeScript/ios](https://github.com/NativeScript/ios/releases) has the dSYMs
  attached, one per platform slice:
  - `ios-arm64NativeScript.framework.dSYM.zip`: iPhone and iPad devices
  - `ios-arm64_x86_64-simulatorNativeScript.framework.dSYM.zip`: iOS simulators
  - `ios-arm64-maccatalystNativeScript.framework.dSYM.zip`: Mac Catalyst

  Each zip unpacks to a dSYM with the same prefix, for example
  `ios-arm64NativeScript.framework.dSYM`. The commands below call it
  `NativeScript.framework.dSYM`.
- **From the xcframework.** The xcframework carries the same dSYMs in
  `<slice>/dSYMs/NativeScript.framework.dSYM`. When the app gets the runtime
  through Swift Package Manager, Xcode downloads it to
  `~/Library/Developer/Xcode/DerivedData/<project>-<hash>/SourcePackages/artifacts/ios-spm/NativeScript/NativeScript.xcframework`.

Check that the UUID matches the one in the log:

```sh
dwarfdump --uuid NativeScript.framework.dSYM
# UUID: 03DD4E84-EE0C-3280-AF5D-5CC4087BB5A5 (arm64) .../DWARF/NativeScript
```

A dSYM with a different UUID gives wrong answers without any error, so do not
skip this step.

## Resolving frames with `atos`

Pass the dSYM, the architecture and the load address from the `Binary images:`
line, then the frame addresses for that image:

```sh
atos -o NativeScript.framework.dSYM -arch arm64 -l 0x104a00000 \
  0x104ca2088 0x104b1ee7c
# v8::internal::CppHeap::CollectGarbage(cppgc::internal::GCConfig) (in NativeScript) + 64
# tns::ModuleInternal::RunModule(v8::Isolate*, std::__1::basic_string<...>) (in NativeScript) (ModuleInternal.mm:217)
```

If you only have the image offset, use a load address of `0x0` and pass the
offset in hex (`2760840` is `0x2a2088`):

```sh
atos -o NativeScript.framework.dSYM -arch arm64 -l 0x0 0x2a2088
```

Use the architecture printed in the `Binary images:` line. Simulator builds on
Intel Macs are `x86_64`.

## Other images in the trace

- **Your app** (`MyApp` above): use the dSYM Xcode produced when you built the
  app (for an archive, Organizer → right-click the archive → Show in Finder →
  `dSYMs`), with the same `atos` command.
- **System libraries** (`UIKitCore`, `libobjc.A.dylib`, `dyld`, ...): their
  names come from their own exported symbols and are usually close enough to
  read. Exact names need the device's system symbols, which Xcode downloads when
  the device is first connected.

## Crash reporters

Crash reporters that symbolicate on their servers (Sentry, Crashlytics and
others) need the runtime's dSYM uploaded next to the app's own, otherwise
frames inside `NativeScript` stay unresolved or show the nearest exported name.
Upload the dSYM that matches the runtime version the app ships, from one of the
locations above.

`NSException.callStackSymbols` names frames the same way as this log, so it has
the same limitation. `NSException.callStackReturnAddresses` gives the raw
addresses for server-side symbolication. See
[Error handling](error-handling.md#crash-reporter-integration).
