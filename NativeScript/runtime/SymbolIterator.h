#ifndef SymbolIterator_h
#define SymbolIterator_h

#include "Common.h"

namespace tns {

class SymbolIterator {
public:
    // On NSArray's prototype template, so every array wrapper inherits it.
    static void Install(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> prototypeTemplate);
private:
    static v8::Local<v8::Object> CreateIteratorObject(v8::Local<v8::Context> context, v8::Local<v8::Value> object);
    static void NextCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
};

}

#endif /* SymbolIterator_h */
