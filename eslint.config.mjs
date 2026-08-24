// Lint setup for the runtime's builtin JavaScript (NativeScript/runtime/js).
// Each file is compiled by BuiltinLoader as a FUNCTION BODY with the fixed
// parameters `exports`, `module`, `binding` and `primordials` (see
// NativeScript/runtime/js/README.md), which are declared as globals here.
// no-undef is the typo net for binding-bag destructures and native-global
// usage alike; no-restricted-properties keeps the captured intrinsics from
// being read off the live globals again.
import globals from 'globals';

// Statics that primordials.js captures, mapped to their replacement. Instance
// methods (Array.prototype.slice and friends) cannot be matched by
// no-restricted-properties on the receiver, so uncurried use of those stays a
// review rule.
const capturedStatics = [
  ['Array', 'isArray', 'ArrayIsArray'],
  ['ArrayBuffer', 'isView', 'ArrayBufferIsView'],
  ['JSON', 'stringify', 'JSONStringify'],
  ['Number', 'isFinite', 'NumberIsFinite'],
  ['Number', 'isInteger', 'NumberIsInteger'],
  ['Number', 'isNaN', 'NumberIsNaN'],
  ['Number', 'parseFloat', 'NumberParseFloat'],
  ['Number', 'parseInt', 'NumberParseInt'],
  ['Object', 'assign', 'ObjectAssign'],
  ['Object', 'create', 'ObjectCreate'],
  ['Object', 'defineProperty', 'ObjectDefineProperty'],
  ['Object', 'freeze', 'ObjectFreeze'],
  ['Object', 'getOwnPropertyDescriptor', 'ObjectGetOwnPropertyDescriptor'],
  ['Object', 'getOwnPropertySymbols', 'ObjectGetOwnPropertySymbols'],
  ['Object', 'getPrototypeOf', 'ObjectGetPrototypeOf'],
  ['Object', 'is', 'ObjectIs'],
  ['Object', 'keys', 'ObjectKeys'],
  ['Object', 'setPrototypeOf', 'ObjectSetPrototypeOf'],
  ['Reflect', 'construct', 'ReflectConstruct'],
  // No ReflectApply primordial: apply goes through the uncurried
  // Function.prototype.apply, which is one property read cheaper.
  ['Reflect', 'apply', 'FunctionPrototypeApply'],
];

// Captured constructors and namespaces. A destructure from `primordials`
// shadows the global, so these only fire on the unguarded reference.
// `Array` and `Reflect` are deliberately absent: builtins still use them bare
// (`instanceof Array`, the live `Reflect.decorate` probe that reflect-metadata
// fills in after init). Array.from has no primordial: copying `arguments` goes
// through an index loop instead, because Array.from depends on the tamperable
// array iterator protocol.
const restrictedGlobals = ['Error', 'FinalizationRegistry', 'Map', 'Number', 'Proxy', 'RangeError', 'Set', 'String', 'TypeError', 'WeakRef'].map((name) => ({
  name,
  message: `Destructure ${name} from primordials — builtins must not read intrinsics off globals user code can replace.`,
}));

const restrictedProperties = capturedStatics.map(
  ([object, property, primordial]) => ({
    object,
    property,
    message: `Use the ${primordial} primordial instead of ${object}.${property} — builtins must not read intrinsics off globals user code can replace.`,
  }),
);

export default [
  {
    files: ['NativeScript/runtime/js/**/*.js'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'script',
      globals: {
        ...globals.es2021,
        exports: 'readonly',
        require: 'readonly',
        module: 'readonly',
        binding: 'readonly',
        primordials: 'readonly',
        internals: 'readonly',
        global: 'readonly',
        console: 'readonly',
        URL: 'readonly',
        URLSearchParams: 'readonly',
        Blob: 'readonly',
        File: 'readonly',
        // Native globals resolved through the metadata interceptor at runtime:
        interop: 'readonly',
        NSUUID: 'readonly',
        CGPoint: 'readonly',
        CGRect: 'readonly',
        CGSize: 'readonly',
        UIEdgeInsets: 'readonly',
        NSRange: 'readonly',
        CFRunLoopGetCurrent: 'readonly',
        CFRunLoopPerformBlock: 'readonly',
        CFRunLoopWakeUp: 'readonly',
        kCFRunLoopDefaultMode: 'readonly',
        // Installed onto the global by inline-functions.js itself and
        // referenced by bare name from its sibling decorators:
        ObjCClass: 'readonly',
        ObjCMethod: 'readonly',
      },
    },
    rules: {
      'no-undef': 'error',
      'no-unused-vars': ['error', { args: 'none', caughtErrors: 'none' }],
      'no-restricted-properties': ['error', ...restrictedProperties],
      'no-restricted-globals': ['error', ...restrictedGlobals],
    },
  },
  {
    // The file that does the capturing.
    files: ['NativeScript/runtime/js/primordials.js'],
    rules: {
      'no-restricted-properties': 'off',
      'no-restricted-globals': 'off',
    },
  },
];
