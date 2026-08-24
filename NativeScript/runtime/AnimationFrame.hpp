//
//  AnimationFrame.hpp
//  NativeScript
//

#ifndef AnimationFrame_hpp
#define AnimationFrame_hpp

#include "Common.h"

namespace tns {

class AnimationFrame {
 public:
  static void Init(v8::Isolate* isolate,
                   v8::Local<v8::ObjectTemplate> globalTemplate);

 private:
  static void RequestAnimationFrame(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  static void CancelAnimationFrame(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  static void PostFrameCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  static void RemoveFrameCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);
};

}  // namespace tns

#endif /* AnimationFrame_hpp */
