declare module "ns:interop" {
  /** A native `void*`. */
  export interface Pointer {
    /** A new pointer `offset` bytes past this one. */
    add(offset: number): Pointer;
    /** A new pointer `offset` bytes before this one. */
    subtract(offset: number): Pointer;
    /**
     * The address as a number. Addresses wider than 53 bits lose precision;
     * `toBigInt` does not.
     */
    toNumber(): number;
    toBigInt(): bigint;
    /** The address in hexadecimal, `0x`-prefixed. */
    toHexString(): string;
    /** The address in decimal. */
    toDecimalString(): string;
    toString(): string;
  }

  /**
   * Pointers are interned per address: constructing one for an address that
   * already has a live `Pointer` returns that object.
   */
  export const Pointer: {
    readonly prototype: Pointer;
    /** A pointer to `address`, or the null pointer when omitted. */
    new (address?: number | bigint): Pointer;
  };

  /**
   * A pointer that owns the memory it points to and frees it when it is
   * garbage collected — what `alloc` returns and `adopt` produces.
   */
  export interface AdoptedPointer extends Pointer {}

  /**
   * A native type: the C primitives in `types`, a struct constructor, an
   * Objective-C class or protocol. Calling one reads a value of that type at
   * a pointer.
   */
  export interface Type<T> {
    (ptr: Pointer): T;
  }

  /** The constructor of a C struct, which doubles as its `Type`. */
  export interface StructType<T> extends Type<T> {
    /** A zero-initialized struct. */
    new (): T;
    /** A struct initialized from the fields of `obj`. */
    new (obj: T): T;
    /** A struct copied from the memory at `obj`. */
    new (obj: Pointer): T;
    /** Whether two structs hold the same bytes. */
    equals(left: T, right: T): boolean;
  }

  /**
   * An object reference whose ownership the native side did not express (a
   * Core Foundation function without an audited ownership convention). The
   * caller decides whether the retain it carries is consumed.
   */
  export interface Unmanaged<T> {
    /** The value, consuming an unbalanced retain of it. */
    takeRetainedValue(): T;
    /** The value, leaving its retain count alone. */
    takeUnretainedValue(): T;
  }

  /**
   * A typed slot in native memory, used for out parameters and pointer
   * arithmetic. Indexing reads and writes the elements that follow it.
   */
  export interface Reference<T> {
    value: T;
    [index: number]: any;
  }

  export const Reference: {
    readonly prototype: Reference<any>;
    /**
     * A reference holding `value`; its native type is fixed the first time
     * it is marshalled.
     */
    new <T>(value?: T): Reference<T>;
    /** A view of the memory at `data`, read and written as `type`. */
    new <T>(type: Type<T>, data: Pointer): Reference<T>;
    /** A reference of type `type` initialized with `value`. */
    new <T>(type: Type<T>, value: any): Reference<T>;
  };

  /**
   * A JS function marshalled as a native function pointer. The pointer stays
   * valid only while this object is reachable from JS.
   */
  export interface FunctionReference<T> {
    (...params: any[]): any;
  }

  export const FunctionReference: {
    readonly prototype: FunctionReference<any>;
    new <T>(func: T): FunctionReference<T>;
  };

  /**
   * The size in bytes of a type or of the value behind an instance: a type
   * from `types`, a struct type or instance, a class or protocol, a native
   * object, reference, pointer, block or C function. Throws for anything else.
   */
  export function sizeof(type: any): number;

  /** `size` bytes of zeroed memory, freed when the pointer is collected. */
  export function alloc(size: number): AdoptedPointer;

  /**
   * Frees memory a pointer does not own. Does nothing for an adopted
   * pointer, whose memory is freed when it is collected.
   */
  export function free(ptr: Pointer): void;

  /**
   * A pointer to the native counterpart of `instance`: a native object,
   * class or protocol, a struct, reference, pointer, block, function
   * reference, C function or ArrayBuffer view. `null` for `null`; throws for
   * anything else.
   */
  export function handleof(instance: any): Pointer;

  /**
   * Decodes UTF-8 from `cString`: `lengthInBytes` bytes, or up to the first
   * NUL when omitted.
   */
  export function stringFromCString(
    cString: Pointer | Reference<any>,
    lengthInBytes?: number
  ): string;

  /** The C primitive types, frozen. */
  export const types: Readonly<{
    void: Type<void>;
    bool: Type<boolean>;
    int8: Type<number>;
    uint8: Type<number>;
    int16: Type<number>;
    uint16: Type<number>;
    int32: Type<number>;
    uint32: Type<number>;
    int64: Type<number>;
    uint64: Type<number>;
    /** C `unsigned long`. */
    ulong: Type<number>;
    /** C `long`. */
    slong: Type<number>;
    float: Type<number>;
    double: Type<number>;
  }>;
}
