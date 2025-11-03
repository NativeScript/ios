#ifndef NativeScriptException_h
#define NativeScriptException_h

#include <string>

#include "Common.h"

namespace tns {

class NativeScriptException {
 public:
  NativeScriptException(const std::string& message);
  NativeScriptException(v8::Isolate* isolate, v8::TryCatch& tc,
                        const std::string& message);
  NativeScriptException(v8::Isolate* isolate, const std::string& message,
                        const std::string& name = "NativeScriptException");
  ~NativeScriptException();
  void ReThrowToV8(v8::Isolate* isolate);
  const std::string& getMessage() const { return message_; }
  const std::string& getStackTrace() const { return stackTrace_; }
  static void OnUncaughtError(v8::Local<v8::Message> message,
                              v8::Local<v8::Value> error);
  static void ShowErrorModal(v8::Isolate* isolate,
                             const std::string& title,
                             const std::string& message,
                             const std::string& stackTrace);
    static void SubmitConsoleErrorPayload(v8::Isolate* isolate,
                                                                                const std::string& payload);

 private:
  v8::Persistent<v8::Value>* javascriptException_;
  std::string name_;
  std::string message_;
  std::string stackTrace_;
  std::string fullMessage_;
  static std::string GetErrorStackTrace(
      v8::Isolate* isolate, const v8::Local<v8::StackTrace>& stackTrace);
  static std::string GetErrorMessage(v8::Isolate* isolate,
                                     v8::Local<v8::Value>& error,
                                     const std::string& prependMessage = "");
  static std::string GetFullMessage(v8::Isolate* isolate,
                                    const v8::TryCatch& tc,
                                    const std::string& jsExceptionMessage);
  static std::string GetFullMessage(v8::Isolate* isolate,
                                    v8::Local<v8::Message> message,
                                    const std::string& jsExceptionMessage);
};

}  // namespace tns

#endif /* NativeScriptException_h */
