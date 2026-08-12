// Same shape as tla-foreground-task.mjs, kept separate so the dynamic-import
// spec is not served the module registry entry the require spec created.
const i32 = new Int32Array(new SharedArrayBuffer(4));
const wait = Atomics.waitAsync(i32, 0, 0);
Atomics.notify(i32, 0);
export const value = await wait.value;
// lets the spec tell "module never completed" apart from "import promise
// never observed the completion"
globalThis.__tlaImportProbeDone = value;
