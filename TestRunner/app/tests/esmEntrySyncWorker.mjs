// A fully synchronous ES module worker entry: `import`/`export` are legal in an
// entry, and boot is observably unchanged. Module code is strict, so the
// message handler is installed on globalThis rather than by bare assignment.
import { WORKER_TAG } from "./esmEntryHelper.mjs";

globalThis.onmessage = function (msg) {
    postMessage(WORKER_TAG + ":" + msg.data);
};
