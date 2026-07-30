# Runtime builtins

The `.js` files in this directory are the runtime's internal JavaScript. At
build time the "Generate RuntimeBuiltins" Xcode phase runs `tools/js2c.mjs`,
which embeds them into `NativeScript/runtime/generated/RuntimeBuiltins.cpp`;
at runtime `BuiltinLoader::RunBuiltin` compiles and executes them with an
`internal/<name>.js` script origin and a process-wide bytecode cache.

## Contract (Node's internalBinding idiom)

Every file is compiled as a **function body** via `v8::ScriptCompiler::CompileFunction`
with one fixed parameter:

```js
const { someNative, anotherNative } = binding;
```

- `binding` is a plain object of natives built by the C++ call site; a file
  that needs nothing from C++ simply doesn't mention it.
- Because the file is a function body, **top-level `return` is legal** — a
  builtin's return value is what `RunBuiltin` hands back to C++ (used to
  return factory functions and init results).
- Strict mode is per-file: start the file with `"use strict";` to opt in.
- Destructure `binding` once, at the top of the file, so the file's native
  dependencies are visible and greppable.

## Rules

- Run at isolate init, before any user code: capture any global you rely on
  (e.g. `globalThis.Event`) eagerly so later monkey-patching can't break you.
- No `import`/`export` — these are classic function bodies, not modules.
- ESLint (`eslint.config.mjs` at the repo root, run by lint-staged) declares
  `binding` and the reachable native globals; `no-undef` is the typo net.
  If a builtin starts using a new native global, add it there.
- File names are kebab-case; the name determines the `BuiltinId` enum value
  (`promise-proxy.js` → `kPromiseProxy`) and the script origin. New files must
  also be added to `tools/js2c-inputs.xcfilelist`.
