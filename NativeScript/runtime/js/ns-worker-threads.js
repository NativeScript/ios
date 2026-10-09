"use strict";

// The `ns:worker_threads` builtin module: the runtime's own Worker, the very
// function the global of that name was created with. See
// docs/ns-builtin-modules.md for the contract and docs/worker-threads.md for
// the constructor's options.

const { Worker } = binding;
const { ObjectFreeze } = primordials;

exports.Worker = Worker;
ObjectFreeze(exports);
