CFArrayRef CFArrayCreateWithString(CFStringRef string);

// Declared for the metadata generator but intentionally left undefined, so the
// symbol is listed in metadata yet absent at runtime.
void TNSFunctionMissingAtRuntime(void);

// Whether the process holds executable memory carrying V8's VM tag (255).
// V8 maps executable memory only when its JIT is on.
bool TNSHasExecutableV8Memory(void);
