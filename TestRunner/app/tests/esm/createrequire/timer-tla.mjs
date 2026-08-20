// Settles only if due JS timers run while the module evaluation promise is
// pending: the resolution rides the ordered lane (a CFRunLoopTimer token),
// which no runloop pass can deliver while the pump's JS frames hold the
// thread. The runtime primitive is used directly so the fixture pins the
// runtime's own ordered-lane timers rather than any app-level polyfill.
export const value = await new Promise(function (resolve) {
    __ns__setTimeout(function () { resolve("timer-ok"); }, 10);
});
