6.4.0-beta.1-v8 (2020-01-14)
====

### Features

- SIMD support
- `NSError**` output parameters support
- Global js error handler

### Bug Fixes

6.2.0-alpha.2-v8 (2019-09-18)
=====

### Features

- [Script code caching](https://v8.dev/blog/improved-code-caching)
- iOS Deployment Target = 9.0
- Log statements are sent to `stderr` using the `NSLog` function
- Wrap native method calls into try/catch statements and throw javascript exception for every caught NSException

### Bug Fixes

 - The `global.performance` object is no longer declared as readonly [#2](https://github.com/NativeScript/ns-v8ios-runtime/issues/2)

6.2.0-alpha.1-v8 (2019-09-18)
=====

Initial public release