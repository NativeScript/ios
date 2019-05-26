#ifndef DictionaryAdapter_h
#define DictionaryAdapter_h

#import <Foundation/NSDictionary.h>
#include "NativeScript.h"

@interface DictionaryAdapter : NSDictionary

-(instancetype)initWithJSObject:(v8::Local<v8::Object>)jsObject isolate:(v8::Isolate*)isolate;

@end

#endif /* DictionaryAdapter_h */
