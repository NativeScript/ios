#include "NativeScriptException.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import <UIKit/UIKit.h>
#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif
#import <objc/message.h>
#import <objc/runtime.h>
#include <sstream>
#include <mutex>
#include <limits>
#include <algorithm>
#include "Caches.h"
#include "Helpers.h"
#include "Runtime.h"
#include "RuntimeConfig.h"

using namespace v8;

namespace {
static UITextView* gErrorStackTextView = nil;
static NSString* gLatestStackText = nil;

struct PendingErrorDisplay {
  uint64_t ticket = 0;
  bool contextCaptured = false;
  bool modalPresented = false;
  bool fallbackScheduled = false;
  v8::Isolate* isolate = nullptr;
  std::string title;
  std::string message;
  std::string rawStack;
  std::string canonicalStack;
  std::string consolePayload;
  int canonicalQuality = -1;
};

static std::mutex gErrorDisplayMutex;
static PendingErrorDisplay gPendingErrorDisplay;
static uint64_t gNextErrorTicket = 1;

}

namespace tns {

// External flag from Runtime.mm to track JavaScript errors
extern bool jsErrorOccurred;
extern bool isErrorDisplayShowing;

static void UpdateDisplayedStackText(const std::string& stackText);
static void RenderErrorModalUI(v8::Isolate* isolate, const std::string& title,
                               const std::string& message, const std::string& stackText);
static void ShowErrorModalSynchronously(const std::string& title,
                                        const std::string& message,
                                        const std::string& stackTrace);
static void ScheduleFallbackPresentation(uint64_t ticket);
static void PresentFallbackIfNeeded(uint64_t ticket);
static std::string ResolveDisplayStack(const PendingErrorDisplay& state);
static int EvaluateStackQuality(const std::string& stackText);
static void ConsiderStackCandidate(PendingErrorDisplay& state, v8::Isolate* isolate,
                                   const std::string& candidateStack);

NativeScriptException::NativeScriptException(const std::string& message) {
  this->javascriptException_ = nullptr;
  this->message_ = message;
  this->name_ = "NativeScriptException";
}

NativeScriptException::NativeScriptException(Isolate* isolate, TryCatch& tc,
                                             const std::string& message) {
  Local<Value> error = tc.Exception();
  this->javascriptException_ = new Persistent<Value>(isolate, tc.Exception());
  this->message_ = GetErrorMessage(isolate, error, message);
  this->stackTrace_ = tns::GetSmartStackTrace(isolate, &tc, error);
  this->fullMessage_ = GetFullMessage(isolate, tc, this->message_);
  this->name_ = "NativeScriptException";
  tc.Reset();
}

NativeScriptException::NativeScriptException(Isolate* isolate, const std::string& message,
                                             const std::string& name) {
  this->name_ = name;
  Local<Value> error = Exception::Error(tns::ToV8String(isolate, message));
  auto context = Caches::Get(isolate)->GetContext();
  error.As<Object>()
      ->Set(context, ToV8String(isolate, "name"), ToV8String(isolate, this->name_))
      .FromMaybe(false);
  this->javascriptException_ = new Persistent<Value>(isolate, error);
  this->message_ = GetErrorMessage(isolate, error, message);
  this->stackTrace_ = GetErrorStackTrace(isolate, Exception::GetStackTrace(error));
  this->fullMessage_ =
      GetFullMessage(isolate, Exception::CreateMessage(isolate, error), this->message_);
}
NativeScriptException::~NativeScriptException() { delete this->javascriptException_; }

void NativeScriptException::OnUncaughtError(Local<v8::Message> message, Local<Value> error) {
  @try {
    Isolate* isolate = message->GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();
    Local<Value> handler;
    id value = Runtime::GetAppConfigValue("discardUncaughtJsExceptions");
    bool isDiscarded = value ? [value boolValue] : false;

    std::string cbName = isDiscarded ? "__onDiscardedError" : "__onUncaughtError";
    bool success = global->Get(context, tns::ToV8String(isolate, cbName)).ToLocal(&handler);

    std::string stackTrace = tns::GetSmartStackTrace(isolate, nullptr, error);
    if (stackTrace.empty()) {
      stackTrace = GetErrorStackTrace(isolate, message->GetStackTrace());
    }
    std::string fullMessage;

    auto errObject = error.As<Object>();
    auto fullMessageString = tns::ToV8String(isolate, "fullMessage");
    if (errObject->HasOwnProperty(context, fullMessageString).ToChecked()) {
      // check if we have a "fullMessage" on the error, and log that instead - since it includes
      // more info about the exception.
      v8::Local<v8::Value> fullMessage_;
      if (errObject->Get(context, fullMessageString).ToLocal(&fullMessage_)) {
        fullMessage = tns::ToString(isolate, fullMessage_);
      } else {
        // Fallback to regular message if fullMessage access fails
        Local<v8::String> messageV8String = message->Get();
        fullMessage = tns::ToString(isolate, messageV8String);
      }
    } else {
      Local<v8::String> messageV8String = message->Get();
      std::string messageString = tns::ToString(isolate, messageV8String);
      fullMessage = messageString + "\n at \n" + stackTrace;
    }

    if (success && handler->IsFunction()) {
      if (error->IsObject()) {
        // Try to set stackTrace property, but don't crash if it fails
        bool stackTraceSet = error.As<Object>()
                                 ->Set(context, tns::ToV8String(isolate, "stackTrace"),
                                       tns::ToV8String(isolate, stackTrace))
                                 .FromMaybe(false);
        if (!stackTraceSet) {
          Log(@"Warning: Failed to set stackTrace property on error object");
        }
      }

      Local<v8::Function> errorHandlerFunc = handler.As<v8::Function>();
      Local<Object> thiz = Object::New(isolate);
      Local<Value> args[] = {error};
      Local<Value> result;
      TryCatch tc(isolate);
      success = errorHandlerFunc->Call(context, thiz, 1, args).ToLocal(&result);
      if (tc.HasCaught()) {
        tns::LogError(isolate, tc);
      }

      // Don't crash if error handler call failed - just log it
      if (!success) {
        Log(@"Warning: Error handler function call failed");
      }
    }

    if (!isDiscarded) {
      NSString* reasonStr = [NSString stringWithUTF8String:fullMessage.c_str()];
      if (reasonStr == nil) {
        reasonStr = @"(invalid UTF-8 message from JS)";
      }

      NSString* name = @"NativeScriptUncaughtJSException";

      // In debug mode, show error modal instead of crashing
      if (RuntimeConfig.IsDebug) {
        // Mark that a JavaScript error occurred
        jsErrorOccurred = true;
        Log(@"***** JavaScript exception occurred "
            @"in debug mode *****\n");
        Log(@"%s", fullMessage.c_str());
        Log(@"%s", stackTrace.c_str());
        // Log(@"🎨 CALLING ShowErrorModal for OnUncaughtError - should display branded modal");

        // Show the error modal with same message as terminal
        std::string errorTitle = "Uncaught JavaScript Exception";

        // Extract just the error type/message (first line) for cleaner display
        std::string errorMessage = "JavaScript error occurred";
        if (reasonStr) {
          std::string fullMsg = [reasonStr UTF8String];
          size_t firstNewline = fullMsg.find('\n');
          if (firstNewline != std::string::npos) {
            errorMessage = fullMsg.substr(0, firstNewline);
          } else {
            errorMessage = fullMsg;
          }
        }

        Log(@"***** End stack trace - Fix error to continue *****\n");

        ShowErrorModal(isolate, errorTitle, errorMessage, stackTrace);

        // Don't crash in debug mode - just return
        return;
      }

      // In release mode, crash as before - BUT NEVER IN DEBUG MODE
      if (!RuntimeConfig.IsDebug) {
        // we throw the exception on main thread so all meta-data is captured
        dispatch_async(dispatch_get_main_queue(), ^(void) {
          NSException* objcException =
              [NSException exceptionWithName:name
                                      reason:reasonStr
                                    userInfo:@{@"sender" : @"onUncaughtError"}];

          Log(@"***** Fatal JavaScript exception - application has been terminated. *****\n");
          Log(@"%@", objcException);
          @throw objcException;
        });
      }
    } else {
      Log(@"NativeScript discarding uncaught JS exception!");
    }
  } @catch (NSException* exception) {
    Log(@"OnUncaughtError: Caught exception during error handling: %@", exception);
    if (RuntimeConfig.IsDebug) {
      Log(@"Debug mode - suppressing crash and continuing");
    } else {
      @throw exception;  // Re-throw in release mode
    }
  }
}

void NativeScriptException::ReThrowToV8(Isolate* isolate) {
  @try {
    // The Isolate::Scope here is necessary because the Exception::Error method internally relies on
    // the Isolate::GetCurrent method which might return null if we do not use the proper scope
    Isolate::Scope scope(isolate);

    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> errObj;

    if (this->javascriptException_ != nullptr) {
      errObj = this->javascriptException_->Get(isolate);
      if (errObj->IsObject()) {
        if (!this->fullMessage_.empty()) {
          bool success = errObj.As<Object>()
                             ->Set(context, tns::ToV8String(isolate, "fullMessage"),
                                   tns::ToV8String(isolate, this->fullMessage_))
                             .FromMaybe(false);
          if (!success) {
            Log(@"Warning: Failed to set fullMessage property on error object");
          }
        } else if (!this->message_.empty()) {
          bool success = errObj.As<Object>()
                             ->Set(context, tns::ToV8String(isolate, "fullMessage"),
                                   tns::ToV8String(isolate, this->message_))
                             .FromMaybe(false);
          if (!success) {
            Log(@"Warning: Failed to set fullMessage property on error object");
          }
        }
      }
    } else if (!this->fullMessage_.empty()) {
      errObj = Exception::Error(tns::ToV8String(isolate, this->fullMessage_));
    } else if (!this->message_.empty()) {
      errObj = Exception::Error(tns::ToV8String(isolate, this->message_));
    } else {
      errObj = Exception::Error(
          tns::ToV8String(isolate, "No javascript exception or message provided."));
    }

    // For critical exceptions (like module loading failures), provide detailed error reporting
    bool isCriticalException = false;

    // Check if this is a critical exception that should show detailed error info
    if (!this->message_.empty()) {
      // Module-related errors should show detailed stack traces
      isCriticalException =
          (this->message_.find("Error calling module function") != std::string::npos ||
           this->message_.find("Cannot evaluate module") != std::string::npos ||
           this->message_.find("Cannot instantiate module") != std::string::npos ||
           this->message_.find("Cannot compile") != std::string::npos);
    }

    if (isCriticalException) {
      // Mark that a JavaScript error occurred
      jsErrorOccurred = true;

      // Create detailed error message similar to OnUncaughtError
      std::string stackTrace = this->stackTrace_;
      std::string fullMessage;

      if (!this->fullMessage_.empty()) {
        fullMessage = this->fullMessage_;
      } else {
        fullMessage = this->message_ + "\n at \n" + stackTrace;
      }

      // Always log the detailed error for critical exceptions (both debug and release)
      Log(@"***** JavaScript exception occurred - detailed stack trace follows *****\n");
      Log(@"NativeScript encountered an error:");
      NSString* errorStr = [NSString stringWithUTF8String:fullMessage.c_str()];
      if (errorStr != nil) {
        Log(@"%@", errorStr);
      } else {
        Log(@"(error message contained invalid UTF-8)");
      }

      // Additional guidance after the stack trace for boot/init errors
      Log(@"\n======================================");
      Log(@"Error on app initialization.");
      Log(@"Please fix the error and save the file to auto reload the app.");
      Log(@"======================================");

      // In debug mode, continue execution; in release mode, terminate
      if (RuntimeConfig.IsDebug) {
        Log(@"***** End stack trace - showing error modal and continuing execution *****\n");

        // Show error modal in debug mode
        std::string errorTitle = "JavaScript Error";

        // Extract just the error message (first line) for the title
        std::string errorMessage = this->message_;
        size_t firstNewline = errorMessage.find('\n');
        if (firstNewline != std::string::npos) {
          errorMessage = errorMessage.substr(0, firstNewline);
        }

        // Prefer a clean stack for the modal
        std::string displayStack = stackTrace;
        if (displayStack.empty()) {
          displayStack = fullMessage;  // last resort
        }
        ShowErrorModal(isolate, errorTitle, errorMessage, displayStack);

        // In debug mode, DON'T throw the exception - just return to prevent crash
        // The error modal will be shown and the app will continue running
        Log(@"***** Error handled gracefully - app continues without crash *****\n");
        return;
      } else {
        Log(@"***** End stack trace - terminating application *****\n");
        // In release mode, create proper message and call OnUncaughtError for termination
        Local<v8::Message> message = Exception::CreateMessage(isolate, errObj);
        OnUncaughtError(message, errObj);
        return;  // OnUncaughtError will terminate, so we don't continue
      }
    }

    // For non-critical exceptions:
    if (RuntimeConfig.IsDebug) {
      // Be gentle, state case in logs and allow developer to continue
      Log(@"Debug mode - suppressing throw to continue: %s", this->message_.c_str());
    } else {
      // just re-throw normally
      isolate->ThrowException(errObj);
    }
  } @catch (NSException* exception) {
    Log(@"ReThrowToV8: Caught exception during error handling: %@", exception);
    if (RuntimeConfig.IsDebug) {
      Log(@"Debug mode - suppressing crash and continuing");
    } else {
      @throw exception;  // Re-throw in release mode
    }
  }
}

std::string NativeScriptException::GetErrorMessage(Isolate* isolate, Local<Value>& error,
                                                   const std::string& prependMessage) {
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  Local<Context> context = cache->GetContext();

  // get whole error message from previous stack
  std::stringstream ss;

  if (prependMessage != "") {
    ss << prependMessage << std::endl;
  }

  std::string errMessage;
  bool hasFullErrorMessage = false;
  auto v8FullMessage = tns::ToV8String(isolate, "fullMessage");
  if (error->IsObject() && error.As<Object>()->Has(context, v8FullMessage).ToChecked()) {
    hasFullErrorMessage = true;
    Local<Value> errMsgVal;
    bool success = error.As<Object>()->Get(context, v8FullMessage).ToLocal(&errMsgVal);
    if (success && !errMsgVal.IsEmpty()) {
      errMessage = tns::ToString(isolate, errMsgVal.As<v8::String>());
    } else {
      errMessage = "";
      if (!success) {
        Log(@"Warning: Failed to get fullMessage property from error object");
      }
    }
    ss << errMessage;
  }

  MaybeLocal<v8::String> str = error->ToDetailString(context);
  if (!str.IsEmpty()) {
    v8::String::Utf8Value utfError(isolate, str.FromMaybe(Local<v8::String>()));
    if (hasFullErrorMessage) {
      ss << std::endl;
    }
    ss << *utfError;
  }

  return ss.str();
}

std::string NativeScriptException::GetErrorStackTrace(Isolate* isolate,
                                                      const Local<StackTrace>& stackTrace) {
  if (stackTrace.IsEmpty()) {
    return "";
  }

  std::stringstream ss;

  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);

  int frameCount = stackTrace->GetFrameCount();

  for (int i = 0; i < frameCount; i++) {
    Local<StackFrame> frame = stackTrace->GetFrame(isolate, i);
    std::string funcName = tns::ToString(isolate, frame->GetFunctionName());
    std::string srcName = tns::ToString(isolate, frame->GetScriptName());
    int lineNumber = frame->GetLineNumber();
    int column = frame->GetColumn();

    ss << "\t" << (i > 0 ? "at " : "") << funcName.c_str() << "(" << srcName.c_str() << ":"
       << lineNumber << ":" << column << ")" << std::endl;
  }

  return ss.str();
}
std::string NativeScriptException::GetFullMessage(Isolate* isolate, const TryCatch& tc,
                                                  const std::string& jsExceptionMessage) {
  std::string loggedMessage = GetFullMessage(isolate, tc.Message(), jsExceptionMessage);
  if (!tc.CanContinue()) {
    std::stringstream errM;
    errM << std::endl
         << "An uncaught error has occurred and V8's TryCatch block CAN'T be continued. ";
    loggedMessage = errM.str() + loggedMessage;
  }
  return loggedMessage;
}

std::string NativeScriptException::GetFullMessage(Isolate* isolate, Local<v8::Message> message,
                                                  const std::string& jsExceptionMessage) {
  Local<Context> context = isolate->GetEnteredOrMicrotaskContext();

  std::stringstream ss;
  ss << jsExceptionMessage;

  // get script name
  Local<Value> scriptResName = message->GetScriptResourceName();

  // get stack trace
  std::string stackTraceMessage = GetErrorStackTrace(isolate, message->GetStackTrace());

  if (!scriptResName.IsEmpty() && scriptResName->IsString()) {
    ss << std::endl << "File: (" << tns::ToString(isolate, scriptResName.As<v8::String>());
  } else {
    ss << std::endl << "File: (<unknown>";
  }
  ss << ":" << message->GetLineNumber(context).ToChecked() << ":" << message->GetStartColumn()
     << ")" << std::endl
     << std::endl;
  ss << "StackTrace: " << std::endl << stackTraceMessage << std::endl;

  std::string loggedMessage = ss.str();

  // TODO: Log the error
  // tns::LogError(isolate, tc);

  return loggedMessage;
}

void NativeScriptException::ShowErrorModal(Isolate* isolate, const std::string& title,
                                           const std::string& message,
                                           const std::string& stackTrace) {
  if (!RuntimeConfig.IsDebug) {
    return;
  }

  if (!Runtime::showErrorDisplay()) {
    return;
  }

  uint64_t ticketToSchedule = 0;

  {
    std::lock_guard<std::mutex> lock(gErrorDisplayMutex);

    // If the console already presented this error (console-first scenario), just enrich the context.
    if (gPendingErrorDisplay.ticket != 0 && !gPendingErrorDisplay.contextCaptured &&
        gPendingErrorDisplay.modalPresented) {
      gPendingErrorDisplay.contextCaptured = true;
      gPendingErrorDisplay.isolate = isolate;
      gPendingErrorDisplay.title = title;
      gPendingErrorDisplay.message = message;
      gPendingErrorDisplay.rawStack = stackTrace;
      ConsiderStackCandidate(gPendingErrorDisplay, isolate, stackTrace);
      return;
    }

    gPendingErrorDisplay.ticket = gNextErrorTicket++;
    gPendingErrorDisplay.contextCaptured = true;
    gPendingErrorDisplay.modalPresented = false;
    gPendingErrorDisplay.fallbackScheduled = true;
    gPendingErrorDisplay.isolate = isolate;
    gPendingErrorDisplay.title = title;
    gPendingErrorDisplay.message = message;
    gPendingErrorDisplay.rawStack = stackTrace;
    gPendingErrorDisplay.consolePayload.clear();
    gPendingErrorDisplay.canonicalStack.clear();
    gPendingErrorDisplay.canonicalQuality = -1;
    ConsiderStackCandidate(gPendingErrorDisplay, isolate, stackTrace);
    ticketToSchedule = gPendingErrorDisplay.ticket;
  }

  if (ticketToSchedule != 0) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      ScheduleFallbackPresentation(ticketToSchedule);
    });
  }
}

void NativeScriptException::SubmitConsoleErrorPayload(Isolate* isolate, const std::string& payload) {
  if (!RuntimeConfig.IsDebug) {
    return;
  }

  if (!Runtime::showErrorDisplay()) {
    return;
  }

  PendingErrorDisplay stateSnapshot;
  bool presentNow = false;
  bool updateExisting = false;

  auto promoteConsolePayload = [&](const std::string& text, v8::Isolate* payloadIsolate) {
    gPendingErrorDisplay.consolePayload = text;
    if (payloadIsolate != nullptr) {
      gPendingErrorDisplay.isolate = payloadIsolate;
    }
    gPendingErrorDisplay.canonicalStack = text;
    gPendingErrorDisplay.canonicalQuality = std::numeric_limits<int>::max();
  };

  {
    std::lock_guard<std::mutex> lock(gErrorDisplayMutex);

    auto buildDefaultContext = [&](void) {
      gPendingErrorDisplay.title = "JavaScript Error";
      std::string firstLine = payload;
      size_t newlinePos = payload.find('\n');
      if (newlinePos != std::string::npos) {
        firstLine = payload.substr(0, newlinePos);
      }
      gPendingErrorDisplay.message = firstLine;
      gPendingErrorDisplay.rawStack = payload;
      promoteConsolePayload(payload, isolate);
    };

    if (gPendingErrorDisplay.ticket == 0) {
      gPendingErrorDisplay.ticket = gNextErrorTicket++;
      gPendingErrorDisplay.canonicalStack.clear();
      gPendingErrorDisplay.canonicalQuality = -1;
    }

    if (!gPendingErrorDisplay.contextCaptured && !gPendingErrorDisplay.modalPresented) {
      // Console-first scenario for a brand new error
      gPendingErrorDisplay.modalPresented = true;
      gPendingErrorDisplay.isolate = isolate;
      buildDefaultContext();
      stateSnapshot = gPendingErrorDisplay;
      presentNow = true;
    } else if (!gPendingErrorDisplay.modalPresented) {
      // Context captured (or pending) but UI not yet shown – prefer the console payload
      if (!gPendingErrorDisplay.contextCaptured) {
        buildDefaultContext();
      }
      if (isolate != nullptr) {
        gPendingErrorDisplay.isolate = isolate;
      }
      promoteConsolePayload(payload, isolate);
      gPendingErrorDisplay.modalPresented = true;
      stateSnapshot = gPendingErrorDisplay;
      presentNow = true;
    } else {
      // Modal already visible (fallback or previous payload) – just update the text content
      promoteConsolePayload(payload, isolate);
      updateExisting = true;
    }
  }

  if (presentNow) {
    std::string displayStack = stateSnapshot.canonicalStack.empty()
                                    ? (stateSnapshot.consolePayload.empty()
                                           ? ResolveDisplayStack(stateSnapshot)
                                           : stateSnapshot.consolePayload)
                                    : stateSnapshot.canonicalStack;
    RenderErrorModalUI(stateSnapshot.isolate, stateSnapshot.title, stateSnapshot.message,
                       displayStack);
  } else if (updateExisting) {
    std::string displayStack = gPendingErrorDisplay.canonicalStack.empty()
                                    ? (gPendingErrorDisplay.consolePayload.empty()
                                           ? ResolveDisplayStack(gPendingErrorDisplay)
                                           : gPendingErrorDisplay.consolePayload)
                                    : gPendingErrorDisplay.canonicalStack;
    UpdateDisplayedStackText(displayStack);
  }
}

static void ScheduleFallbackPresentation(uint64_t ticket) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                   PresentFallbackIfNeeded(ticket);
                 });
}

static void PresentFallbackIfNeeded(uint64_t ticket) {
  PendingErrorDisplay snapshot;
  bool shouldPresent = false;

  {
    std::lock_guard<std::mutex> lock(gErrorDisplayMutex);
    if (gPendingErrorDisplay.ticket == ticket && !gPendingErrorDisplay.modalPresented) {
      gPendingErrorDisplay.modalPresented = true;
      snapshot = gPendingErrorDisplay;
      shouldPresent = true;
    }
  }

  if (!shouldPresent) {
    return;
  }

  std::string finalStack = ResolveDisplayStack(snapshot);

  RenderErrorModalUI(snapshot.isolate, snapshot.title, snapshot.message, finalStack);
}

static std::string ResolveDisplayStack(const PendingErrorDisplay& state) {
  if (!state.canonicalStack.empty()) {
    size_t previewLen = std::min<size_t>(state.canonicalStack.size(), 120);
    std::string preview = state.canonicalStack.substr(0, previewLen);
    Log(@"[ErrorDisplay] resolved stack (canonical) len=%zu preview=%@",
        state.canonicalStack.size(), [NSString stringWithUTF8String:preview.c_str()]);
    return state.canonicalStack;
  }

  std::string bestStack;
  int bestQuality = std::numeric_limits<int>::min();

  auto consider = [&](const std::string& candidate, v8::Isolate* isolate) {
    if (candidate.empty()) {
      return;
    }
    std::string normalized = candidate;
    if (isolate != nullptr) {
      std::string remapped = tns::RemapStackTraceIfAvailable(isolate, candidate);
      if (!remapped.empty()) {
        normalized = remapped;
      }
    }
    int candidateQuality = EvaluateStackQuality(normalized);
    size_t previewLen = std::min<size_t>(normalized.size(), 120);
    std::string preview = normalized.substr(0, previewLen);
    Log(@"[ErrorDisplay] consider: quality=%d len=%zu preview=%@", candidateQuality,
        normalized.size(), [NSString stringWithUTF8String:preview.c_str()]);
    if (candidateQuality > bestQuality ||
        (candidateQuality == bestQuality && normalized.size() > bestStack.size())) {
      bestStack = normalized;
      bestQuality = candidateQuality;
    }
  };

  if (!state.canonicalStack.empty()) {
    consider(state.canonicalStack, nullptr);
  }
  if (!state.consolePayload.empty()) {
    consider(state.consolePayload, state.isolate);
  }
  if (!state.rawStack.empty()) {
    consider(state.rawStack, state.isolate);
  }

  if (bestStack.empty()) {
    return state.message;
  }

  size_t finalPreviewLen = std::min<size_t>(bestStack.size(), 120);
  std::string finalPreview = bestStack.substr(0, finalPreviewLen);
  Log(@"[ErrorDisplay] resolved stack quality=%d len=%zu preview=%@", bestQuality,
      bestStack.size(), [NSString stringWithUTF8String:finalPreview.c_str()]);

  return bestStack;
}

static size_t CountOccurrences(const std::string& haystack, const std::string& needle) {
  if (haystack.empty() || needle.empty()) {
    return 0;
  }
  size_t count = 0;
  size_t pos = haystack.find(needle, 0);
  while (pos != std::string::npos) {
    ++count;
    pos = haystack.find(needle, pos + needle.length());
  }
  return count;
}

static int EvaluateStackQuality(const std::string& stackText) {
  if (stackText.empty()) {
    return std::numeric_limits<int>::min();
  }

  auto hasAny = [&](const std::initializer_list<const char*>& tokens) {
    for (const auto* token : tokens) {
      if (stackText.find(token) != std::string::npos) {
        return true;
      }
    }
    return false;
  };

  int score = 0;

  size_t tsFrames = CountOccurrences(stackText, ".ts:") +
                    CountOccurrences(stackText, ".tsx:") +
                    CountOccurrences(stackText, ".vue:");
  if (tsFrames > 0) {
    score += 60;
    score += static_cast<int>(tsFrames) * 5;
  }

  if (hasAny({"webpack:/", "file: src/", "sourceURL"})) {
    score += 20;
  }

  size_t newlineCount = CountOccurrences(stackText, "\n");
  if (newlineCount > 0) {
    score += static_cast<int>(std::min<size_t>(20, newlineCount));
  }

  if (stackText.find(" at ") != std::string::npos) {
    score += 10;
  }

  int penalty = 0;
  penalty += static_cast<int>(CountOccurrences(stackText, "file:///app/")) * 3;
  penalty += static_cast<int>(CountOccurrences(stackText, ".bundle.js")) * 2;
  penalty = std::min(penalty, score / 2);  // don't let bundle frames dominate completely
  score -= penalty;

  score += static_cast<int>(std::min<size_t>(10, stackText.size() / 400));

  if (score <= 0) {
    score = 1;  // ensure non-empty strings beat truly empty candidates
  }

  return score;
}

static void ConsiderStackCandidate(PendingErrorDisplay& state, v8::Isolate* isolate,
                                   const std::string& candidateStack) {
  if (candidateStack.empty()) {
    return;
  }

  v8::Isolate* effectiveIsolate = isolate != nullptr ? isolate : state.isolate;
  std::string normalized = candidateStack;
  if (effectiveIsolate != nullptr) {
    std::string remapped = tns::RemapStackTraceIfAvailable(effectiveIsolate, candidateStack);
    if (!remapped.empty()) {
      normalized = remapped;
    }
  }

  int quality = EvaluateStackQuality(normalized);
  if (quality < 0 && state.canonicalQuality >= 0) {
    return;
  }

  bool shouldReplace = false;
  if (quality > state.canonicalQuality) {
    shouldReplace = true;
  } else if (quality == state.canonicalQuality && normalized.size() > state.canonicalStack.size()) {
    shouldReplace = true;
  }

  if (state.canonicalStack.empty()) {
    shouldReplace = true;
  }

  if (shouldReplace) {
    state.canonicalStack = normalized;
    state.canonicalQuality = quality;
  }
}

static void UpdateDisplayedStackText(const std::string& stackText) {
  NSString* stackNSString = [NSString stringWithUTF8String:stackText.c_str()];
  if (stackNSString == nil) {
    stackNSString = @"(invalid UTF-8 stack trace)";
  }
  gLatestStackText = stackNSString;

  auto applyUpdate = ^{
    if (gErrorStackTextView != nil) {
      gErrorStackTextView.text = gLatestStackText;
      gErrorStackTextView.contentOffset = CGPointMake(0, 0);
    }
  };

  if ([NSThread isMainThread]) {
    applyUpdate();
  } else {
    dispatch_async(dispatch_get_main_queue(), applyUpdate);
  }
}

static void RenderErrorModalUI(v8::Isolate* isolate, const std::string& title,
                               const std::string& message, const std::string& stackText) {
  if (!RuntimeConfig.IsDebug || !Runtime::showErrorDisplay()) {
    return;
  }

  // Always prefer the shared pending state's canonical/console text so callers cannot
  // accidentally overwrite with a worse stack.
  std::string stackForModal = stackText;
  {
    std::lock_guard<std::mutex> lock(gErrorDisplayMutex);
    if (!gPendingErrorDisplay.canonicalStack.empty()) {
      stackForModal = gPendingErrorDisplay.canonicalStack;
    } else if (!gPendingErrorDisplay.consolePayload.empty()) {
      stackForModal = gPendingErrorDisplay.consolePayload;
    }
  }
  if (stackForModal.empty()) {
    stackForModal = message;
  }

  // Final guard: remap here as well so the UI always matches the terminal output,
  // even if earlier stages missed remapping due to timing.
  if (isolate != nullptr) {
    std::string maybeRemapped = tns::RemapStackTraceIfAvailable(isolate, stackForModal);
    if (!maybeRemapped.empty()) {
      stackForModal = maybeRemapped;
    }
  }

  UpdateDisplayedStackText(stackForModal);

  bool alreadyShowing = isErrorDisplayShowing;

  UIApplication* app = [UIApplication sharedApplication];
  if (!alreadyShowing && app.windows.count == 0 && app.connectedScenes.count == 0) {
    Log(@"Note: JavaScript error during boot.");
    Log(@"================================");
    Log(@"%s", stackForModal.c_str());
    Log(@"================================");
    Log(@"Please fix the error and save the file to auto reload the app.");
    Log(@"================================");
    return;
  }

  if (alreadyShowing) {
    return;
  }

  isErrorDisplayShowing = true;

  auto showSynchronously = ^{
    @try {
      // Log(@"[ShowErrorModal] On main thread - showing modal synchronously %s", message.c_str());
      ShowErrorModalSynchronously(title, message, stackForModal);
    } @catch (NSException* exception) {
      Log(@"Error details - Title: %s, Message: %s", title.c_str(), message.c_str());
    }
  };

  if ([NSThread isMainThread]) {
    showSynchronously();
  } else {
    dispatch_sync(dispatch_get_main_queue(), showSynchronously);
  }
}

static void ShowErrorModalSynchronously(const std::string& title,
                                        const std::string& message,
                                        const std::string& stackTrace) {
  // Use static variables to keep strong references and prevent deallocation
  static UIWindow* __attribute__((unused)) foundationWindowRef =
      nil;  // Keep foundation window alive
  static UIWindow* errorWindow = nil;

  // BOOTSTRAP iOS APP LIFECYCLE: Ensure basic app infrastructure exists
  // This is crucial when JavaScript fails before UIApplicationMain completes normal setup
  UIApplication* sharedApp = [UIApplication sharedApplication];

  // If no windows exist, create a foundational window to establish the hierarchy
  if (sharedApp.windows.count == 0) {
    // Log(@"🚀 Bootstrap: No app windows exist - creating foundational window hierarchy");

    // Create a basic foundational window that mimics what UIApplicationMain would create
    UIWindow* foundationWindow = nil;

    if (@available(iOS 13.0, *)) {
      // For iOS 13+, we need to handle window scenes properly
      UIWindowScene* foundationScene = nil;

      // Try to find or create a window scene
      for (UIScene* scene in sharedApp.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
          foundationScene = (UIWindowScene*)scene;
          // Log(@"🚀 Bootstrap: Found existing scene for foundation window");
          break;
        }
      }

      if (foundationScene) {
        foundationWindow = [[UIWindow alloc] initWithWindowScene:foundationScene];
        // Log(@"🚀 Bootstrap: Created foundation window with existing scene");
      } else {
        // If no scenes exist, create a window without scene (iOS 12 style fallback)
        foundationWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        // Log(@"🚀 Bootstrap: Created foundation window without scene (emergency mode)");
      }
    } else {
      // iOS 12 and below - simple window creation
      foundationWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
      // Log(@"🚀 Bootstrap: Created foundation window for iOS 12");
    }

    if (foundationWindow) {
      // Set up a basic root view controller to establish the hierarchy
      UIViewController* foundationViewController = [[UIViewController alloc] init];
      foundationViewController.view.backgroundColor = [UIColor blackColor];  // Invisible foundation
      foundationWindow.rootViewController = foundationViewController;
      foundationWindow.windowLevel = UIWindowLevelNormal;  // Base level
      foundationWindow.backgroundColor = [UIColor blackColor];

      // Make it key and visible to establish the window hierarchy
      [foundationWindow makeKeyAndVisible];

      // Keep a strong reference to prevent deallocation
      foundationWindowRef = foundationWindow;

      // Give iOS a moment to process the new window hierarchy (we're already on main queue)
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);


      // Detailed window hierarchy inspection
      if (sharedApp.windows.count == 0) {
        // Log(@"🚀 Bootstrap: 🚨 CRITICAL: Foundation window not in app.windows hierarchy!");
        // Log(@"🚀 Bootstrap: This indicates a fundamental iOS window system issue");

        // Try alternative window registration approach
        // Log(@"🚀 Bootstrap: Attempting alternative window registration...");
        [foundationWindow.layer setNeedsDisplay];
        [foundationWindow.layer displayIfNeeded];
        [foundationWindow layoutIfNeeded];

        // Force another run loop cycle
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
      }
    } else {
      // Log(@"🚀 Bootstrap: WARNING - Failed to create foundation window");
    }
  } else {
    // Log(@"🚀 Bootstrap: App windows already exist (%lu) - no bootstrap needed",
    //       (unsigned long)sharedApp.windows.count);
  }

  // Create a dedicated error window that works even during early app lifecycle

  // Clean up any previous error window
  if (errorWindow) {
    errorWindow.hidden = YES;
    [errorWindow resignKeyWindow];
    errorWindow = nil;
    gErrorStackTextView = nil;
  }

  // iOS 13+ requires proper window scene handling
  if (@available(iOS 13.0, *)) {
    // Try to find an existing window scene, or create one if needed
    UIWindowScene* windowScene = nil;

    // First, try to find an existing connected scene
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
      if ([scene isKindOfClass:[UIWindowScene class]]) {
        windowScene = (UIWindowScene*)scene;
        // Log(@"🎨 Found existing window scene for error modal");
        break;
      }
    }

    if (windowScene) {
      errorWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
      // Log(@"🎨 Created error window with existing scene");
    } else {
      // Fallback: create window with screen bounds (older behavior)
      errorWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
      // Log(@"🎨 Created error window with screen bounds (no scene available)");
    }
  } else {
    // iOS 12 and below
    errorWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    // Log(@"🎨 Created error window for iOS 12");
  }

  errorWindow.windowLevel = UIWindowLevelAlert + 1000;  // Above everything
  errorWindow.backgroundColor = [UIColor colorWithRed:0.15
                                                green:0.15
                                                 blue:0.15
                                                alpha:1.0];  // Match the dark gray theme

  // Ensure window is visible regardless of app state
  errorWindow.hidden = NO;
  errorWindow.alpha = 1.0;

  // Create the error view controller
  UIViewController* errorViewController = [[UIViewController alloc] init];
  errorViewController.view.backgroundColor = [UIColor colorWithRed:0.15
                                                             green:0.15
                                                              blue:0.15
                                                             alpha:1.0];  // Dark gray tech theme

  // Content container
  UIView* contentView = [[UIView alloc] init];
  contentView.translatesAutoresizingMaskIntoConstraints = NO;
  [errorViewController.view addSubview:contentView];

  // NativeScript Logo (will be loaded asynchronously)
  UIImageView* logoImageView = [[UIImageView alloc] init];
  logoImageView.contentMode = UIViewContentModeScaleAspectFit;
  logoImageView.translatesAutoresizingMaskIntoConstraints = NO;
  logoImageView.backgroundColor = [UIColor clearColor];
  [contentView addSubview:logoImageView];

  // Load NativeScript logo asynchronously
  NSString* logoURL = @"https://github.com/NativeScript/artwork/raw/refs/heads/main/logo/export/"
                      @"NativeScript_Logo_Wide_Transparent_White_Rounded_White.png";
  NSURLRequest* request = [NSURLRequest requestWithURL:[NSURL URLWithString:logoURL]];
  NSURLSessionDataTask* logoTask = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
          if (data && !error) {
            UIImage* logoImage = [UIImage imageWithData:data];
            if (logoImage) {
              dispatch_async(dispatch_get_main_queue(), ^{
                logoImageView.image = logoImage;
                // Log(@"🎨 NativeScript logo loaded successfully");
              });
            } else {
              // Log(@"🎨 Failed to create image from logo data");
            }
          } else {
            // Log(@"🎨 Failed to load NativeScript logo: %@", error.localizedDescription);
            // Fallback: show text logo
            dispatch_async(dispatch_get_main_queue(), ^{
              UILabel* fallbackLogo = [[UILabel alloc] init];
              fallbackLogo.text = @"NativeScript";
              fallbackLogo.textColor = [UIColor whiteColor];
              fallbackLogo.font = [UIFont boldSystemFontOfSize:28];
              fallbackLogo.textAlignment = NSTextAlignmentCenter;
              fallbackLogo.translatesAutoresizingMaskIntoConstraints = NO;
              [contentView addSubview:fallbackLogo];

              // Update constraints for fallback
              [NSLayoutConstraint activateConstraints:@[
                [fallbackLogo.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:40],
                [fallbackLogo.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor],
                [fallbackLogo.heightAnchor constraintEqualToConstant:40]
              ]];
            });
          }
        }];
  [logoTask resume];

  // Instruction message (between logo and error)
  UILabel* instructionLabel = [[UILabel alloc] init];
  instructionLabel.text = @"Please resolve the error shown to continue.";
  instructionLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
  instructionLabel.font = [UIFont systemFontOfSize:16];
  instructionLabel.textAlignment = NSTextAlignmentCenter;
  instructionLabel.numberOfLines = 0;
  instructionLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [contentView addSubview:instructionLabel];

  // Error title (simplified)
  UILabel* errorTitleLabel = [[UILabel alloc] init];
  errorTitleLabel.text = @"⚠️ JavaScript Error";
  errorTitleLabel.textColor = [UIColor colorWithRed:1.0
                                              green:0.6
                                               blue:0.2
                                              alpha:1.0];  // Orange warning
  errorTitleLabel.font = [UIFont boldSystemFontOfSize:18];
  errorTitleLabel.textAlignment = NSTextAlignmentCenter;
  errorTitleLabel.numberOfLines = 0;
  errorTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [contentView addSubview:errorTitleLabel];

  // Stack trace container - BLACK background for terminal-like feel
  UIView* stackTraceContainer = [[UIView alloc] init];
  stackTraceContainer.backgroundColor = [UIColor blackColor];  // Pure black for terminal feel
  stackTraceContainer.layer.cornerRadius = 12;
  stackTraceContainer.layer.borderWidth = 1;
  stackTraceContainer.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
  stackTraceContainer.translatesAutoresizingMaskIntoConstraints = NO;
  [contentView addSubview:stackTraceContainer];

  // Log(@"errorToDisplay from in NativeScriptException ShowErrorModal: %s", stackTrace.c_str());
  // Stack trace text view - with proper terminal styling
  UITextView* stackTraceTextView = [[UITextView alloc] init];
  NSString* initialStackText = gLatestStackText;
  if (initialStackText == nil) {
    initialStackText = [NSString stringWithUTF8String:stackTrace.c_str()];
    if (initialStackText == nil) {
      initialStackText = @"(invalid UTF-8 stack trace)";
    }
    gLatestStackText = initialStackText;
  }
  stackTraceTextView.text = initialStackText;
  stackTraceTextView.textColor = [UIColor colorWithRed:0.0
                                                 green:1.0
                                                  blue:0.0
                                                 alpha:1.0];  // Terminal green
  stackTraceTextView.backgroundColor = [UIColor clearColor];
  stackTraceTextView.font = [UIFont fontWithName:@"Menlo" size:16];  // Monospace
  stackTraceTextView.editable = NO;
  stackTraceTextView.selectable = YES;
  stackTraceTextView.scrollEnabled = YES;
  stackTraceTextView.contentInset = UIEdgeInsetsMake(15, 15, 15, 15);
  stackTraceTextView.translatesAutoresizingMaskIntoConstraints = NO;
  [stackTraceContainer addSubview:stackTraceTextView];
  gErrorStackTextView = stackTraceTextView;


  // Hot-reload indicator
  UILabel* hotReloadLabel = [[UILabel alloc] init];
  hotReloadLabel.text = @"Fix the error and save your changes to continue.";
  hotReloadLabel.textColor = [UIColor colorWithRed:0.2
                                             green:0.8
                                              blue:1.0
                                             alpha:1.0];  // Bright blue
  hotReloadLabel.font = [UIFont systemFontOfSize:14];
  hotReloadLabel.textAlignment = NSTextAlignmentCenter;
  hotReloadLabel.numberOfLines = 0;
  hotReloadLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [contentView addSubview:hotReloadLabel];

  // Set up constraints
  [NSLayoutConstraint activateConstraints:@[
    // Content view
    [contentView.topAnchor
        constraintEqualToAnchor:errorViewController.view.safeAreaLayoutGuide.topAnchor],
    [contentView.leadingAnchor constraintEqualToAnchor:errorViewController.view.leadingAnchor],
    [contentView.trailingAnchor constraintEqualToAnchor:errorViewController.view.trailingAnchor],
    [contentView.bottomAnchor
        constraintEqualToAnchor:errorViewController.view.safeAreaLayoutGuide.bottomAnchor],

    // NativeScript Logo at top center
    [logoImageView.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:30],
    [logoImageView.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor],
    [logoImageView.heightAnchor constraintEqualToConstant:60],
    [logoImageView.widthAnchor constraintLessThanOrEqualToConstant:300],

    // Instruction message below logo
    [instructionLabel.topAnchor constraintEqualToAnchor:logoImageView.bottomAnchor constant:20],
    [instructionLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
    [instructionLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor
                                                    constant:-20],

    // Error title below instruction
    [errorTitleLabel.topAnchor constraintEqualToAnchor:instructionLabel.bottomAnchor constant:20],
    [errorTitleLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
    [errorTitleLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor
                                                   constant:-20],

    // Stack trace container (black terminal-like background) - flexible height
    [stackTraceContainer.topAnchor constraintEqualToAnchor:errorTitleLabel.bottomAnchor
                                                  constant:15],
    [stackTraceContainer.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor
                                                      constant:20],
    [stackTraceContainer.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor
                                                       constant:-20],

    // Stack trace text view (terminal green text on black)
    [stackTraceTextView.topAnchor constraintEqualToAnchor:stackTraceContainer.topAnchor],
    [stackTraceTextView.leadingAnchor constraintEqualToAnchor:stackTraceContainer.leadingAnchor],
    [stackTraceTextView.trailingAnchor constraintEqualToAnchor:stackTraceContainer.trailingAnchor],
    [stackTraceTextView.bottomAnchor constraintEqualToAnchor:stackTraceContainer.bottomAnchor],

    [hotReloadLabel.topAnchor constraintEqualToAnchor:stackTraceContainer.bottomAnchor constant:15],
    [hotReloadLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
    [hotReloadLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20],
    [hotReloadLabel.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-30],
  ]];

  // Present the error window with robust error handling
  errorWindow.rootViewController = errorViewController;

  // Force the window to be visible with multiple approaches
  // Log(@"Attempting to display error modal...");

  @try {
    // Primary approach: makeKeyAndVisible
    [errorWindow makeKeyAndVisible];
    // Log(@"makeKeyAndVisible called successfully");

    // Secondary approach: force visibility
    errorWindow.hidden = NO;
    errorWindow.alpha = 1.0;

    // Force a layout pass to ensure UI is rendered
    [errorWindow layoutIfNeeded];
    [errorViewController.view layoutIfNeeded];

    // Bring window to front (alternative to makeKeyAndVisible)
    [errorWindow bringSubviewToFront:errorViewController.view];

    // Verify the window is in the window hierarchy
    NSArray* windows = [UIApplication sharedApplication].windows;
    BOOL windowInHierarchy = [windows containsObject:errorWindow];
    // Log(@"Error window in app windows: %@", windowInHierarchy ? @"YES" : @"NO");

    if (!windowInHierarchy) {

      // Aggressive fix 1: Try to force the window to be key and make it the only visible window
      Log(@"Total app windows before fix: %lu", (unsigned long)windows.count);

      // Hide all other windows to ensure our error window is the only one visible
      for (UIWindow* window in windows) {
        if (window != errorWindow) {
          window.hidden = YES;
          window.alpha = 0.0;
          // Log(@"🎨 Hiding existing window: %@", window);
        }
      }

      // Force our window to be the key window and front-most
      errorWindow.windowLevel = UIWindowLevelAlert + 2000;  // Even higher level
      errorWindow.hidden = NO;
      errorWindow.alpha = 1.0;

      // Try multiple approaches to make it visible
      [errorWindow makeKeyAndVisible];
      [errorWindow becomeKeyWindow];

      // Force immediate layout and display
      [errorWindow setNeedsLayout];
      [errorWindow layoutIfNeeded];
      [errorWindow setNeedsDisplay];
    }

    // Log(@"Error modal displayed successfully!");

  } @catch (NSException* exception) {
    // Log(@"ERROR: Failed to display error modal: %@", exception);
    // Log(@"Attempting fallback display method...");

    // Fallback: Try to show an alert instead
    NSString* fallbackMessage = gLatestStackText;
    if (fallbackMessage == nil) {
      fallbackMessage = [NSString stringWithUTF8String:stackTrace.c_str()];
      if (fallbackMessage == nil) {
        fallbackMessage = @"(invalid UTF-8 stack trace)";
      }
    }

    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:@"⚠️ JavaScript Error"
                                            message:fallbackMessage
                                     preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* action = [UIAlertAction actionWithTitle:@"Continue Development 🚀"
                                                     style:UIAlertActionStyleDefault
                                                   handler:nil];
    [alert addAction:action];

    // Try to present the alert
    UIViewController* topViewController = errorViewController;
    [topViewController presentViewController:alert
                                    animated:YES
                                  completion:^{
                                    Log(@"🎨 Fallback alert displayed successfully!");
                                  }];
  }

  // Add a delay to ensure the UI is fully rendered and give the modal time to stabilize
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   //  Log(@"🎨 Error modal UI fully rendered and stable - app should stay alive
                   //  now");

                   // Force the main run loop to process any pending events to keep the app
                   // responsive
                   CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
                 });
}  // namespace

}  // namespace tns
