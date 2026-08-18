// Type declarations for the runtime's public `ns:` builtin modules — one
// .d.ts per module, mirroring @types/node's layout and the "one module, one
// source file" rule in docs/ns-builtin-modules.md. The declared surfaces must
// stay in sync with that document (NsRuntimeTests.js / NsUtilTests.js /
// HttpEsmLoaderTests.js assert the export sets at runtime).
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
// The `node:` compatibility shims (`node:util`, `node:module`, `node:url`) are
// deliberately not declared here: programs that include @types/node already
// have declarations for those specifiers, and a second one would clash with
// them. A shim exposing less than Node does is a runtime concern, documented
// in docs/ns-builtin-modules.md, not something to restate in types that would
// then conflict.

/// <reference path="./ns-module.d.ts" />
/// <reference path="./ns-runtime.d.ts" />
/// <reference path="./ns-util.d.ts" />
