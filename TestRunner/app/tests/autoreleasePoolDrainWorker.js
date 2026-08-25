// The autorelease happens inside one timer callout, and the report is sent
// from the NEXT one: the dealloc log can only be present in between if the
// worker drains a pool per callout. Without that the pool only drains at
// worker death, after the report is sent.
TNSClearOutput();
setTimeout(function () {
    TNSAllocLog.autoreleaseInstance();
    setTimeout(function () {
        postMessage(TNSGetOutput());
    }, 0);
}, 0);
