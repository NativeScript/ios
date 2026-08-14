// Type declarations for the runtime's public surfaces — `ns:` builtin modules
// (one .d.ts per module, mirroring @types/node's layout and the "one module, one
// source file" rule in docs/ns-builtin-modules.md) and globals such as
// NativeClass. The `ns:` surfaces must stay in sync with that document
// (NsRuntimeTests.js / NsUtilTests.js / HttpEsmLoaderTests.js assert the
// export sets at runtime).
//
// `ns:` is not a resolvable package specifier, so these are ambient
// declarations: they apply program-wide once this file is in the TypeScript
// program. Pull it in with either
//
//   /// <reference types="@nativescript/ios" />
//
// or a tsconfig entry:
//
//   { "include": ["node_modules/@nativescript/ios/types/index.d.ts"] }
//
// These files are the source of truth for `ns:*` types. Downstream type
// packages must reference them, not redeclare the modules — two
// `declare module` blocks for the same specifier conflict.
//
// The `node:util` compatibility shim is deliberately not declared here:
// programs that include @types/node already have a `node:util` declaration,
// and a second one would clash with it.

/// <reference path="./ns-module.d.ts" />
/// <reference path="./ns-runtime.d.ts" />
/// <reference path="./ns-util.d.ts" />
/// <reference path="./ns-nativeclass.d.ts" />
