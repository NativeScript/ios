#ifndef AOTCalls_h
#define AOTCalls_h

#include <objc/runtime.h>

#include <cstdint>
#include <vector>

#include "Common.h"
#include "NativeScriptAOT.h"

// Binding of app-compiled AOT call stubs (see NativeScriptAOT.h) to the
// prototype templates built by MetadataBuilder.
namespace tns::aot {

struct ClassStubs;

struct Binding {
  // Installed as the FunctionTemplate callback in place of the generic one.
  v8::FunctionCallback callback = nullptr;
  // Stored in the site's CacheItem::userData_, where the callback reads it.
  void* handler = nullptr;
};

// Registers the stubs exported by the app binary, if any. Every runtime calls
// it before building its first prototype template; later calls are no-ops.
void DiscoverExternalStubs();

// The function handed to the app's __ns_register_aot_calls. Registrations
// outside that call are ignored.
void Register(const char* className, const char* selector, bool isStatic,
              NSAOTCallHandler handler);

// The stubs that apply to a class's template: those registered under its own
// name, then under each ObjC superclass's name, nearest first. A class's
// template can re-register a member it inherits (protocol members are added
// to every adopting class), and the own member shadows the ancestor's, so a
// stub registered for the ancestor must bind there too; it messages the same
// selector, so it is valid for the descendant.
struct StubScope {
  std::vector<const ClassStubs*> classes;
  bool empty() const { return classes.empty(); }
};

// Callers resolve it once per Register* pass and look members up with it.
// Empty, without touching the ObjC runtime, when no stubs are registered.
StubScope FindStubScope(const char* className);

bool FindInstanceMethod(const StubScope& scope, SEL selector, Binding& out);
bool FindStaticMethod(const StubScope& scope, SEL selector, Binding& out);
bool FindInstanceGetter(const StubScope& scope, SEL getter, Binding& out);
bool FindStaticGetter(const StubScope& scope, SEL getter, Binding& out);

// Counted only while MethodCallProfiler is enabled.
uint64_t ServedCallCount();
uint64_t DeclinedCallCount();

}  // namespace tns::aot

#endif /* AOTCalls_h */
