/**
 * Decorates a class that extends a native type. All properties are optional.
 * This runtime implements the `ios` side; `android` is accepted and ignored.
 *
 * `@NativeClass` and `@NativeClass({ ios: { ... } })` are both valid.
 * Passing the class directly (`NativeClass(MyClass)`) applies empty options.
 * On worker isolates this is a no-op; only the main isolate registers
 * native ES classes.
 */
interface NativeClassIOSMethodSignature {
  returns?: any;
  params?: any[];
}

interface NativeClassIOSOptions {
  /**
   * Objective-C class name to register eagerly. When omitted, the ES class
   * name is used and registration stays lazy until first native use.
   */
  name?: string;
  protocols?: any[];
  /**
   * Maps to `static ObjCExposedMethods`. Keys are Objective-C selectors.
   */
  methods?: { [selector: string]: NativeClassIOSMethodSignature };
}

interface NativeClassAndroidOptions {
  name?: string;
  interfaces?: any[];
}

interface NativeClassOptions {
  ios?: NativeClassIOSOptions;
  android?: NativeClassAndroidOptions;
}

declare function NativeClass<T extends { new (...args: any[]): {} }>(
  constructor: T
): T;
declare function NativeClass(
  options?: NativeClassOptions
): <T extends { new (...args: any[]): {} }>(constructor: T) => T;
