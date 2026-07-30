// Lint setup for the runtime's builtin JavaScript (NativeScript/runtime/js).
// Each file is compiled by BuiltinLoader as a FUNCTION BODY with the single
// fixed parameter `binding` (see NativeScript/runtime/js/README.md), so
// sourceType is "commonjs" (allows top-level return) and `binding` is a
// declared global. no-undef is the typo net for binding-bag destructures and
// native-global usage alike.
import globals from 'globals';

export default [
  {
    files: ['NativeScript/runtime/js/**/*.js'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'commonjs',
      globals: {
        ...globals.es2021,
        binding: 'readonly',
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
    },
  },
];
