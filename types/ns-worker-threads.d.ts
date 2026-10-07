declare module "ns:worker_threads" {
  /**
   * The quality of service of a worker's thread, in Apple's terms. Omitting
   * it leaves the runtime's operation queue at its own default.
   */
  export type WorkerPriority =
    | "userInteractive"
    | "userInitiated"
    | "default"
    | "utility"
    | "background";

  /**
   * iOS-specific worker options. A non-object value throws a `TypeError`;
   * keys the runtime does not know are ignored.
   */
  export interface WorkerIosOptions {
    /**
     * A non-string or unrecognized name throws a `TypeError`. Wins over the
     * deprecated top-level `iosPriority` when both are given.
     */
    priority?: WorkerPriority;
  }

  /**
   * Node's `resourceLimits`, in megabytes. A value that is not a number
   * throws a `TypeError`; a non-finite one, one worth less than a byte, or
   * one too large to hold in bytes throws a `RangeError`. Node's
   * `stackSizeMb` and `codeRangeSizeMb` are ignored, like any other key the
   * runtime does not know.
   */
  export interface WorkerResourceLimits {
    /** Caps the worker isolate's old generation. */
    maxOldGenerationSizeMb?: number;
    /** Caps the worker isolate's young generation. */
    maxYoungGenerationSizeMb?: number;
    /**
     * NativeScript extension: the isolate's JS dispatch table reservation, a
     * whole number of megabytes from 1 to 256 (a fractional or out-of-range
     * value throws a `RangeError`). Worker isolates reserve 64 MB when it is
     * omitted; the main isolate keeps V8's default.
     */
    jsDispatchTableSizeMb?: number;
  }

  /**
   * The options the runtime's `Worker` constructor understands. `null` for
   * either object means the same as leaving it out.
   */
  export interface WorkerOptions {
    ios?: WorkerIosOptions | null;
    resourceLimits?: WorkerResourceLimits | null;
    /** @deprecated Use `ios.priority`, which wins when both are given. */
    iosPriority?: WorkerPriority;
  }

  /** The subset of the DOM `Event` surface a worker event carries. */
  export interface WorkerEvent {
    readonly type: string;
    readonly target: Worker | null;
    readonly defaultPrevented: boolean;
    preventDefault(): void;
  }

  /** `message` and `messageerror`; for the latter, `data` is the failure. */
  export interface WorkerMessageEvent extends WorkerEvent {
    readonly data: unknown;
    readonly ports: readonly object[];
  }

  /**
   * `error`. Only primitives cross the isolate boundary, so `error` is always
   * `null` and the worker's stack arrives as the `stackTrace` string.
   */
  export interface WorkerErrorEvent extends WorkerEvent {
    readonly message: string;
    readonly filename: string;
    readonly lineno: number;
    readonly error: null;
    readonly stackTrace: string;
  }

  export interface WorkerEventListenerOptions {
    capture?: boolean;
    once?: boolean;
    passive?: boolean;
  }

  export interface Worker {
    /**
     * `transfer` lists the `ArrayBuffer`s and `MessagePort`s in the message
     * to move rather than clone; it must be an array when given.
     */
    postMessage(message: unknown, transfer?: readonly object[]): void;
    /**
     * Stops the worker wherever it is, its entry script included, without
     * reporting an error.
     */
    terminate(): void;
    onmessage: ((this: Worker, event: WorkerMessageEvent) => unknown) | null;
    onmessageerror:
      | ((this: Worker, event: WorkerMessageEvent) => unknown)
      | null;
    /** Returning a truthy value handles the error, like `preventDefault()`. */
    onerror: ((this: Worker, event: WorkerErrorEvent) => unknown) | null;
    addEventListener(
      type: "message" | "messageerror",
      listener: (this: Worker, event: WorkerMessageEvent) => unknown,
      options?: boolean | WorkerEventListenerOptions
    ): void;
    addEventListener(
      type: "error",
      listener: (this: Worker, event: WorkerErrorEvent) => unknown,
      options?: boolean | WorkerEventListenerOptions
    ): void;
    addEventListener(
      type: string,
      listener: (this: Worker, event: WorkerEvent) => unknown,
      options?: boolean | WorkerEventListenerOptions
    ): void;
    removeEventListener(
      type: string,
      listener: (this: Worker, event: never) => unknown,
      options?: boolean | { capture?: boolean }
    ): void;
    dispatchEvent(event: object): boolean;
  }

  /**
   * The runtime's `Worker` constructor: the very function the global of that
   * name was created with, however `globalThis.Worker` has been reassigned
   * since. `scriptPath` is resolved the way the global constructor resolves
   * it (`~/` for the app root, `./` relative to the calling script).
   */
  export const Worker: {
    readonly prototype: Worker;
    new (scriptPath: string, options?: WorkerOptions | null): Worker;
  };
}

// Script-level declarations are global. A program with a DOM lib already has
// a `WorkerOptions`, which these members merge into, so the runtime's options
// type-check on the global constructor too; a program without one gets just
// these members. The `Worker` variable follows @types/node's rule for its own
// globals: when a DOM lib declares the global (detected through `onmessage`,
// which only the DOM libs put on `globalThis`), that declaration is reused
// verbatim so the two `declare var`s agree, and otherwise the module's
// constructor becomes the global.
interface WorkerOptions {
  ios?: import("ns:worker_threads").WorkerIosOptions | null;
  resourceLimits?: import("ns:worker_threads").WorkerResourceLimits | null;
  /** @deprecated Use `ios.priority`, which wins when both are given. */
  iosPriority?: import("ns:worker_threads").WorkerPriority;
}

declare var Worker: typeof globalThis extends {
  onmessage: any;
  Worker: infer T;
}
  ? T
  : typeof import("ns:worker_threads").Worker;
