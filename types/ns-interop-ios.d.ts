declare module "ns:interop/ios" {
  import type { AdoptedPointer, Pointer, Type } from "ns:interop";

  /**
   * Makes `ptr` own the memory it points to, so it is freed when the pointer
   * is collected. Returns `ptr` itself.
   */
  export function adopt(ptr: Pointer): AdoptedPointer;

  /**
   * An ArrayBuffer over the bytes of `data`, without copying them. The
   * buffer keeps `data` alive for as long as it is reachable.
   */
  export function bufferFromData(data: NSData & object): ArrayBuffer;

  /** The Objective-C types, frozen. */
  export const types: Readonly<{
    id: Type<any>;
    class: Type<any>;
    selector: Type<string>;
    protocol: Type<any>;
    unichar: Type<string>;
    /** Pointer-sized, with `void`'s encoding. */
    noop: Type<void>;
  }>;
}

declare module "ns:interop/visionos" {
  export * from "ns:interop/ios";
}

declare module "ns:interop/macos" {
  export * from "ns:interop/ios";
}

// Merges into the class @nativescript/types-ios declares, so `bufferFromData`
// takes a real NSData there and any object in a program without those types.
// Declared empty on purpose: a member here would be added to that class.
interface NSData {}
