#ifndef GCProtectedSet_h
#define GCProtectedSet_h

#include "Common.h"

namespace tns {

class Runtime;

/// GCProtectedSet is a CPPGC-traceable object which ensures that certain objects are kept alive
class GCProtectedSet final: public cppgc::GarbageCollected<GCProtectedSet> {
public:
    static void Init(v8::Local<v8::Context> context);

    void Trace(cppgc::Visitor* visitor) const;

    GCProtectedSet(v8::Isolate* isolate): isolate_(isolate) { }
private:
    v8::Isolate* isolate_;
};

}

#endif /* GCProtected_h */
