// Linked with -sectcreate __DATA __TNSMetadata metadata-arm64.bin.
extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");

// Looked up by name with dlsym from NativeScript.framework; keep the symbol
// name and signature stable.
__attribute__((visibility("default"), used)) const void* NativeScriptDefaultMetadata(void) {
  return &startOfMetadataSection;
}
