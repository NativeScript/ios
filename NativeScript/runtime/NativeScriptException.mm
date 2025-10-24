#include "NativeScriptException.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import <UIKit/UIKit.h>
#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif
#import <objc/message.h>
#import <objc/runtime.h>
#include <sstream>
#include "Caches.h"
#include "Helpers.h"
#include "Runtime.h"
#include "RuntimeConfig.h"

using namespace v8;

namespace tns {

// External flag from Runtime.mm to track JavaScript errors
extern bool jsErrorOccurred;

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
  this->stackTrace_ = GetErrorStackTrace(isolate, tc.Message()->GetStackTrace());
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

    std::string stackTrace = GetErrorStackTrace(isolate, message->GetStackTrace());
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

      // In debug mode, show beautiful error modal instead of crashing
      if (RuntimeConfig.IsDebug) {
        // Mark that a JavaScript error occurred
        jsErrorOccurred = true;
        Log(@"***** JavaScript exception occurred "
            @"in debug mode *****\n");
        Log(@"%s", fullMessage.c_str());
        Log(@"%s", stackTrace.c_str());
        // NSLog(@"🎨 CALLING ShowErrorModal for OnUncaughtError - should display beautiful branded "
        //       @"modal...");

        // Show the beautiful error modal with SAME comprehensive message as terminal
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

        // Use the same comprehensive fullMessage that the terminal uses (identical stack traces)
        std::string completeStackTrace = reasonStr ? [reasonStr UTF8String] : fullMessage;
        Log(@"***** End stack trace - Fix error to continue *****\n");
        ShowErrorModal(errorTitle, errorMessage, stackTrace);

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

        // Show beautiful error modal in debug mode with SAME detailed message as terminal
        std::string errorTitle = "JavaScript Error";

        // Extract just the error message (first line) for the title
        std::string errorMessage = this->message_;
        size_t firstNewline = errorMessage.find('\n');
        if (firstNewline != std::string::npos) {
          errorMessage = errorMessage.substr(0, firstNewline);
        }

        // Use the same comprehensive fullMessage that the terminal uses
        ShowErrorModal(errorTitle, errorMessage, fullMessage);

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

void NativeScriptException::ShowErrorModal(const std::string& title, const std::string& message,
                                           const std::string& stackTrace) {
  if (!RuntimeConfig.IsDebug) {
    return;
  }

    // only show when enabled via nativescript.config
  if (Runtime::showErrorDisplay() == false) {
    return;
  }

  // For boot-level crashes, try a simpler approach first
  UIApplication* app = [UIApplication sharedApplication];

  // If we're in a very early boot state with no windows/scenes, use a simple approach
  if (app.windows.count == 0 && app.connectedScenes.count == 0) {
    Log(@"Note: JavaScript error during boot.");
    Log(@"================================");
    Log(@"%s", stackTrace.c_str());
    Log(@"================================");
    Log(@"Please fix the error and save the file to auto reload the app.");
    Log(@"================================");

    // Create a nuclear option window for boot crashes; attach to a UIWindowScene on iOS 13+
    @try {
      dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication* app = [UIApplication sharedApplication];

// Try to ensure a scene exists on iOS 13+
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
        if (@available(iOS 13.0, *)) {
          if (app.connectedScenes.count == 0) {
            // NSLog(@"🎨 Boot: requesting scene session activation");
            UISceneActivationRequestOptions* opts = [[UISceneActivationRequestOptions alloc] init];
            [app requestSceneSessionActivation:nil
                                  userActivity:nil
                                       options:opts
                                  errorHandler:^(NSError* error) {
                                    Log(@"🎨 Boot: scene activation error: %@", error);
                                  }];
          }
        }
#endif

        // Slight delay to allow scene creation
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
              // NSLog(@"🎨 Creating nuclear boot error window...");

              UIWindow* bootWindow = nil;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
              if (@available(iOS 13.0, *)) {
                UIWindowScene* winScene = nil;
                for (UIScene* scene in app.connectedScenes) {
                  if ([scene isKindOfClass:[UIWindowScene class]]) {
                    winScene = (UIWindowScene*)scene;
                    break;
                  }
                }
                if (winScene) {
                  bootWindow = [[UIWindow alloc] initWithWindowScene:winScene];
                  bootWindow.frame = winScene.coordinateSpace.bounds;
                  Log(@"🎨 Boot: using scene-backed window");
                }
              }
#endif

              if (!bootWindow) {
                bootWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
                // NSLog(@"🎨 Boot: using frame-backed window (no scene available)");
              }

              bootWindow.windowLevel = UIWindowLevelAlert + 2000;
              bootWindow.backgroundColor = [UIColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0];
              bootWindow.hidden = NO;
              bootWindow.alpha = 1.0;

              // Basic view controller + label
              UIViewController* bootVC = [[UIViewController alloc] init];
              bootVC.view.backgroundColor = [UIColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0];

              UILabel* bootErrorLabel = [[UILabel alloc] init];
              bootErrorLabel.text =
                  [NSString stringWithFormat:@"🚨 BOOT ERROR 🚨\n\n%@\n\n🔧 STACK TRACE:\n%@\n\n💡 Fix "
                                             @"the error and restart the app",
                                             [NSString stringWithUTF8String:message.c_str()],
                                             [NSString stringWithUTF8String:stackTrace.c_str()]];
              bootErrorLabel.textColor = [UIColor whiteColor];
              bootErrorLabel.font = [UIFont boldSystemFontOfSize:16];
              bootErrorLabel.textAlignment = NSTextAlignmentCenter;
              bootErrorLabel.numberOfLines = 0;
              bootErrorLabel.translatesAutoresizingMaskIntoConstraints = NO;
              [bootVC.view addSubview:bootErrorLabel];

              [NSLayoutConstraint activateConstraints:@[
                [bootErrorLabel.centerXAnchor constraintEqualToAnchor:bootVC.view.centerXAnchor],
                [bootErrorLabel.centerYAnchor constraintEqualToAnchor:bootVC.view.centerYAnchor],
                [bootErrorLabel.leadingAnchor
                    constraintGreaterThanOrEqualToAnchor:bootVC.view.leadingAnchor
                                                constant:20],
                [bootErrorLabel.trailingAnchor
                    constraintLessThanOrEqualToAnchor:bootVC.view.trailingAnchor
                                             constant:-20]
              ]];

              bootWindow.rootViewController = bootVC;

              [bootWindow makeKeyAndVisible];
              [bootWindow layoutIfNeeded];
              CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);

              // NSLog(@"🎨 Nuclear boot error window created and displayed! key=%@ hidden=%@
              // alpha=%.2f",
              //       bootWindow.isKeyWindow ? @"YES" : @"NO",
              //       bootWindow.hidden ? @"YES" : @"NO",
              //       bootWindow.alpha);

              static UIWindow* __attribute__((unused)) persistentBootWindow = nil;
              persistentBootWindow = bootWindow;
            });
      });
    } @catch (NSException* exception) {
      // NSLog(@"🎨 Even nuclear boot window failed: %@", exception);
      Log(@"Boot error details are in the logs above.");
    }

    return;  // Exit early for boot-level crashes
  }

  // For normal crashes, proceed with the full UI
  // Ensure we don't crash during UI creation
  // Make this synchronous if we're already on the main thread to prevent race conditions
  if ([NSThread isMainThread]) {
    @try {
      NativeScriptException::showErrorModalSynchronously(title, message, stackTrace);
    } @catch (NSException* exception) {
      // NSLog(@"Failed to create error modal UI: %@", exception);
      Log(@"Error details - Title: %s, Message: %s", title.c_str(), message.c_str());
    }
  } else {
    dispatch_sync(dispatch_get_main_queue(), ^{
      @try {
        NativeScriptException::showErrorModalSynchronously(title, message, stackTrace);
      } @catch (NSException* exception) {
        // NSLog(@"Failed to create error modal UI: %@", exception);
        Log(@"Error details - Title: %s, Message: %s", title.c_str(), message.c_str());
      }
    });
  }
}

void NativeScriptException::showErrorModalSynchronously(const std::string& title,
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
    // NSLog(@"🚀 Bootstrap: No app windows exist - creating foundational window hierarchy");

    // Create a basic foundational window that mimics what UIApplicationMain would create
    UIWindow* foundationWindow = nil;

    if (@available(iOS 13.0, *)) {
      // For iOS 13+, we need to handle window scenes properly
      UIWindowScene* foundationScene = nil;

      // Try to find or create a window scene
      for (UIScene* scene in sharedApp.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
          foundationScene = (UIWindowScene*)scene;
          // NSLog(@"🚀 Bootstrap: Found existing scene for foundation window");
          break;
        }
      }

      if (foundationScene) {
        foundationWindow = [[UIWindow alloc] initWithWindowScene:foundationScene];
        // NSLog(@"🚀 Bootstrap: Created foundation window with existing scene");
      } else {
        // If no scenes exist, create a window without scene (iOS 12 style fallback)
        foundationWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        // NSLog(@"🚀 Bootstrap: Created foundation window without scene (emergency mode)");
      }
    } else {
      // iOS 12 and below - simple window creation
      foundationWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
      // NSLog(@"🚀 Bootstrap: Created foundation window for iOS 12");
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

      // NSLog(@"🚀 Bootstrap: Foundation window established - app now has basic window hierarchy");
      // NSLog(@"🚀 Bootstrap: Foundation window frame: %@",
      //       NSStringFromCGRect(foundationWindow.frame));
      // NSLog(@"🚀 Bootstrap: Foundation window isKeyWindow: %@",
      //       foundationWindow.isKeyWindow ? @"YES" : @"NO");
      // NSLog(@"🚀 Bootstrap: Foundation window hidden: %@", foundationWindow.hidden ? @"YES" :
      // @"NO"); NSLog(@"🚀 Bootstrap: Foundation window alpha: %.2f", foundationWindow.alpha);
      // NSLog(@"🚀 Bootstrap: Foundation window level: %.0f", foundationWindow.windowLevel);
      // NSLog(@"🚀 Bootstrap: Foundation window rootViewController: %@",
      //       foundationWindow.rootViewController);

      // Give iOS a moment to process the new window hierarchy (we're already on main queue)
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);

      // Check again after run loop processing
      // NSLog(@"🚀 Bootstrap: App windows after bootstrap: %lu",
      //       (unsigned long)sharedApp.windows.count);
      // NSLog(@"🚀 Bootstrap: Foundation window still exists: %@", foundationWindow ? @"YES" :
      // @"NO"); NSLog(@"🚀 Bootstrap: Foundation window ref still exists: %@",
      //       foundationWindowRef ? @"YES" : @"NO");

      // Detailed window hierarchy inspection
      if (sharedApp.windows.count > 0) {
        // NSLog(@"🚀 Bootstrap: Window hierarchy details:");
        // for (NSUInteger i = 0; i < sharedApp.windows.count; i++) {
        //   UIWindow* window = sharedApp.windows[i];
        //   NSLog(@"🚀 Bootstrap:   Window %lu: %@ (level: %.0f, key: %@, hidden: %@)", i, window,
        //         window.windowLevel, window.isKeyWindow ? @"YES" : @"NO",
        //         window.hidden ? @"YES" : @"NO");
        // }
      } else {
        // NSLog(@"🚀 Bootstrap: 🚨 CRITICAL: Foundation window not in app.windows hierarchy!");
        // NSLog(@"🚀 Bootstrap: This indicates a fundamental iOS window system issue");

        // Try alternative window registration approach
        // NSLog(@"🚀 Bootstrap: Attempting alternative window registration...");
        [foundationWindow.layer setNeedsDisplay];
        [foundationWindow.layer displayIfNeeded];
        [foundationWindow layoutIfNeeded];

        // Force another run loop cycle
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        // NSLog(@"🚀 Bootstrap: After alternative registration - App windows: %lu",
        //       (unsigned long)sharedApp.windows.count);
      }
    } else {
      // NSLog(@"🚀 Bootstrap: WARNING - Failed to create foundation window");
    }
  } else {
    // NSLog(@"🚀 Bootstrap: App windows already exist (%lu) - no bootstrap needed",
    //       (unsigned long)sharedApp.windows.count);
  }

  // Create a dedicated error window that works even during early app lifecycle

  // Clean up any previous error window
  if (errorWindow) {
    errorWindow.hidden = YES;
    [errorWindow resignKeyWindow];
    errorWindow = nil;
  }

  // iOS 13+ requires proper window scene handling
  if (@available(iOS 13.0, *)) {
    // Try to find an existing window scene, or create one if needed
    UIWindowScene* windowScene = nil;

    // First, try to find an existing connected scene
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
      if ([scene isKindOfClass:[UIWindowScene class]]) {
        windowScene = (UIWindowScene*)scene;
        // NSLog(@"🎨 Found existing window scene for error modal");
        break;
      }
    }

    if (windowScene) {
      errorWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
      // NSLog(@"🎨 Created error window with existing scene");
    } else {
      // Fallback: create window with screen bounds (older behavior)
      errorWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
      // NSLog(@"🎨 Created error window with screen bounds (no scene available)");
    }
  } else {
    // iOS 12 and below
    errorWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    // NSLog(@"🎨 Created error window for iOS 12");
  }

  errorWindow.windowLevel = UIWindowLevelAlert + 1000;  // Above everything
  errorWindow.backgroundColor = [UIColor colorWithRed:0.15
                                                green:0.15
                                                 blue:0.15
                                                alpha:1.0];  // Match the dark gray theme

  // Ensure window is visible regardless of app state
  errorWindow.hidden = NO;
  errorWindow.alpha = 1.0;

  // Create the error view controller with beautiful NativeScript-branded design
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
                // NSLog(@"🎨 NativeScript logo loaded successfully");
              });
            } else {
              // NSLog(@"🎨 Failed to create image from logo data");
            }
          } else {
            // NSLog(@"🎨 Failed to load NativeScript logo: %@", error.localizedDescription);
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

  // NSLog(@"errorToDisplay from in NativeScriptException ShowErrorModal: %s", stackTrace.c_str());
  // Stack trace text view - with proper terminal styling
  UITextView* stackTraceTextView = [[UITextView alloc] init];
  stackTraceTextView.text = [NSString stringWithUTF8String:stackTrace.c_str()];
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

  // TODO: Investigate why the copy action doesn't copy to clipboard
  // Copy button for stack trace
  // UIButton* copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
  // [copyButton setTitle:@"📋 Copy Stack Trace" forState:UIControlStateNormal];
  // [copyButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  // copyButton.backgroundColor = [UIColor colorWithRed:0.3 green:0.3 blue:0.3 alpha:1.0];
  // copyButton.titleLabel.font = [UIFont systemFontOfSize:16];
  // copyButton.layer.cornerRadius = 8;
  // copyButton.translatesAutoresizingMaskIntoConstraints = NO;
  // [contentView addSubview:copyButton];

  // Configure copy button action
  // void (^copyAction)(void) = ^{
  //   UIPasteboard* pasteboard = [UIPasteboard generalPasteboard];
  //   NSString* stackTraceText = [NSString stringWithUTF8String:stackTrace.c_str()];
  //   BOOL wrote = NO;

  //   // Prefer modern UTType on iOS 14+, but avoid hard link to UTTypePlainText (use reflection)
  //   if (@available(iOS 14.0, *)) {
  //     Class UTTypeClass = NSClassFromString(@"UTType");
  //     if (UTTypeClass) {
  //       SEL plainSel = NSSelectorFromString(@"plainText");
  //       if ([UTTypeClass respondsToSelector:plainSel]) {
  //         id plain = ((id(*)(id, SEL))objc_msgSend)(UTTypeClass, plainSel);
  //         if (plain) {
  //           SEL idSel = NSSelectorFromString(@"identifier");
  //           if ([plain respondsToSelector:idSel]) {
  //             NSString* utiIdentifier = ((id(*)(id, SEL))objc_msgSend)(plain, idSel);
  //             if (utiIdentifier.length > 0) {
  //               [pasteboard setValue:stackTraceText forPasteboardType:utiIdentifier];
  //               wrote = YES;
  //             }
  //           }
  //         }
  //       }
  //     }
  //   }

  //   // Fallback to kUTTypePlainText (MobileCoreServices)
  //   if (!wrote) {
  //     [pasteboard setValue:stackTraceText forPasteboardType:(NSString*)kUTTypePlainText];
  //     wrote = YES;
  //   }

  //   // Quick verification; if pasteboard appears empty, try string fallback
  //   if (wrote) {
  //     BOOL hasString = NO;
  //     if ([pasteboard respondsToSelector:@selector(hasStrings)]) {
  //       hasString = pasteboard.hasStrings;
  //     } else {
  //       hasString = (pasteboard.string.length > 0);
  //     }
  //     if (!hasString) {
  //       wrote = NO;
  //     }
  //   }

  //   // Last resort: set .string
  //   if (!wrote || pasteboard.string.length == 0) {
  //     pasteboard.string = stackTraceText;
  //   }

  //   // Show temporary feedback
  //   [copyButton setTitle:@"✅ Copied!" forState:UIControlStateNormal];
  //   copyButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:1.0];

  //   dispatch_after(
  //       dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
  //         [copyButton setTitle:@"📋 Copy Stack Trace" forState:UIControlStateNormal];
  //         copyButton.backgroundColor = [UIColor colorWithRed:0.3 green:0.3 blue:0.3 alpha:1.0];
  //       });
  // };

  // if (@available(iOS 14.0, *)) {
  //   UIAction* action = [UIAction actionWithTitle:@""
  //                                          image:nil
  //                                     identifier:nil
  //                                        handler:^(UIAction* action) {
  //                                          copyAction();
  //                                        }];
  //   [copyButton addAction:action forControlEvents:UIControlEventTouchUpInside];
  // } else {
  //   // For older iOS versions, use target-action pattern
  //   NSObject* target = [[NSObject alloc] init];
  //   objc_setAssociatedObject(target, "copyBlock", copyAction, OBJC_ASSOCIATION_COPY_NONATOMIC);

  //   IMP copyImp = imp_implementationWithBlock(^(id self) {
  //     void (^block)(void) = objc_getAssociatedObject(self, "copyBlock");
  //     if (block) {
  //       block();
  //     }
  //   });

  //   class_addMethod([target class], NSSelectorFromString(@"copyStackTrace"), copyImp, "v@:");
  //   [copyButton addTarget:target
  //                  action:NSSelectorFromString(@"copyStackTrace")
  //        forControlEvents:UIControlEventTouchUpInside];
  // }

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

  // Continue button with NativeScript colors
  // UIButton* continueButton = [UIButton buttonWithType:UIButtonTypeSystem];
  // [continueButton setTitle:@"Continue Development 🚀" forState:UIControlStateNormal];
  // [continueButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  // continueButton.backgroundColor = [UIColor colorWithRed:0.25 green:0.5 blue:1.0 alpha:1.0]; //
  // NativeScript blue continueButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
  // continueButton.layer.cornerRadius = 10;
  // continueButton.translatesAutoresizingMaskIntoConstraints = NO;
  // [contentView addSubview:continueButton];

  // Dismiss action
  // void (^dismissAction)(void) = ^{
  //     NSLog(@"🚀 Developer dismissed error modal - app continues running for hot-reload");
  //     [UIView animateWithDuration:0.3 animations:^{
  //         errorWindow.alpha = 0.0;
  //     } completion:^(BOOL finished) {
  //         errorWindow.hidden = YES;
  //         [errorWindow resignKeyWindow];
  //         NSLog(@"💡 Debug mode: App stays alive - fix your code and save to hot-reload");
  //     }];
  // };

  // Configure button action based on iOS version
  // if (@available(iOS 14.0, *)) {
  //     UIAction* action = [UIAction actionWithTitle:@"" image:nil identifier:nil
  //     handler:^(UIAction* action) {
  //         dismissAction();
  //     }];
  //     [continueButton addAction:action forControlEvents:UIControlEventTouchUpInside];
  // } else {
  //     // For older iOS versions, use target-action pattern
  //     NSObject* target = [[NSObject alloc] init];
  //     objc_setAssociatedObject(target, "dismissBlock", dismissAction,
  //     OBJC_ASSOCIATION_COPY_NONATOMIC);

  //     IMP dismissImp = imp_implementationWithBlock(^(id self) {
  //         void (^block)(void) = objc_getAssociatedObject(self, "dismissBlock");
  //         if (block) {
  //             block();
  //         }
  //     });

  //     class_addMethod([target class], NSSelectorFromString(@"dismissWindow"), dismissImp, "v@:");
  //     [continueButton addTarget:target action:NSSelectorFromString(@"dismissWindow")
  //     forControlEvents:UIControlEventTouchUpInside];
  // }

  // Auto-dismiss after 60 seconds (safety net)
  // dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(),
  // ^{
  //     if (!errorWindow.hidden) {
  //         NSLog(@"⏰ Auto-dismissing error modal after 60 seconds");
  //         dismissAction();
  //     }
  // });

  // Set up constraints for beautiful NativeScript-branded layout
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

    // Copy button below stack trace
    // [copyButton.topAnchor constraintEqualToAnchor:stackTraceContainer.bottomAnchor constant:10],
    // [copyButton.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor],
    // [copyButton.widthAnchor constraintEqualToConstant:200],
    // [copyButton.heightAnchor constraintEqualToConstant:40],

    // Hot-reload indicator below copy button - this will push stack trace up to fill space
    // [hotReloadLabel.topAnchor constraintEqualToAnchor:copyButton.bottomAnchor constant:15],
    // [hotReloadLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
    // [hotReloadLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20],
    // [hotReloadLabel.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-30],
    [hotReloadLabel.topAnchor constraintEqualToAnchor:stackTraceContainer.bottomAnchor constant:15],
    [hotReloadLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
    [hotReloadLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20],
    [hotReloadLabel.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-30],

    // Continue button at bottom
    // [continueButton.topAnchor constraintEqualToAnchor:hotReloadLabel.bottomAnchor constant:25],
    // [continueButton.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
    // [continueButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor
    // constant:-20], [continueButton.heightAnchor constraintEqualToConstant:50],
    // [continueButton.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-30]
  ]];

  // Present the error window with robust error handling
  errorWindow.rootViewController = errorViewController;

  // Force the window to be visible with multiple approaches
  // NSLog(@"🎨 Attempting to display error modal...");

  @try {
    // Primary approach: makeKeyAndVisible
    [errorWindow makeKeyAndVisible];
    // NSLog(@"🎨 makeKeyAndVisible called successfully");

    // Secondary approach: force visibility
    errorWindow.hidden = NO;
    errorWindow.alpha = 1.0;

    // Force a layout pass to ensure UI is rendered
    [errorWindow layoutIfNeeded];
    [errorViewController.view layoutIfNeeded];

    // Bring window to front (alternative to makeKeyAndVisible)
    [errorWindow bringSubviewToFront:errorViewController.view];

    // NSLog(@"🎨 Error window properties: hidden=%@, alpha=%.2f, windowLevel=%.0f",
    //       errorWindow.hidden ? @"YES" : @"NO", errorWindow.alpha, errorWindow.windowLevel);

    // NSLog(@"🎨 Error window frame: %@", NSStringFromCGRect(errorWindow.frame));
    // NSLog(@"🎨 Error window rootViewController: %@", errorWindow.rootViewController);

    // Verify the window is in the window hierarchy
    NSArray* windows = [UIApplication sharedApplication].windows;
    BOOL windowInHierarchy = [windows containsObject:errorWindow];
    // NSLog(@"🎨 Error window in app windows: %@", windowInHierarchy ? @"YES" : @"NO");

    if (!windowInHierarchy) {
      // NSLog(@"🎨 WARNING: Error window not found in app windows hierarchy!");
      // NSLog(@"🎨 FIXING: Forcing window into hierarchy using aggressive methods...");

      // Aggressive fix 1: Try to force the window to be key and make it the only visible window
      Log(@"🎨 Total app windows before fix: %lu", (unsigned long)windows.count);

      // Hide all other windows to ensure our error window is the only one visible
      for (UIWindow* window in windows) {
        if (window != errorWindow) {
          window.hidden = YES;
          window.alpha = 0.0;
          // NSLog(@"🎨 Hiding existing window: %@", window);
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

      // Manual approach: Add ourselves to a window scene if possible
      if (@available(iOS 13.0, *)) {
        for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
          if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene* windowScene = (UIWindowScene*)scene;
            // NSLog(@"🎨 Found scene: %@ with %lu windows", scene,
            //       (unsigned long)windowScene.windows.count);

            // Check if our window is in this scene
            if (![windowScene.windows containsObject:errorWindow]) {
              // NSLog(@"🎨 Error window not in scene - this is the core issue!");
            }
            break;
          }
        }
      }

      // SIMPLIFIED NUCLEAR OPTION: Create a basic error window that works even during boot
      if (windows.count == 0) {
        // NSLog(@"🎨 SIMPLIFIED NUCLEAR: Creating basic error window for boot-level crash");

        // Create the simplest possible window that can display
        UIWindow* simpleWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        simpleWindow.windowLevel = UIWindowLevelAlert + 1000;
        simpleWindow.backgroundColor = [UIColor redColor];
        simpleWindow.hidden = NO;
        simpleWindow.alpha = 1.0;

        // Create a basic view controller
        UIViewController* simpleVC = [[UIViewController alloc] init];
        simpleVC.view.backgroundColor = [UIColor redColor];

        // Create error label
        UILabel* errorLabel = [[UILabel alloc] initWithFrame:simpleWindow.bounds];
        errorLabel.text =
            [NSString stringWithFormat:@"🚨 BOOT ERROR 🚨\n\n%@\n\nRestart the app after fixing",
                                       [NSString stringWithUTF8String:message.c_str()]];
        errorLabel.textColor = [UIColor whiteColor];
        errorLabel.font = [UIFont boldSystemFontOfSize:20];
        errorLabel.textAlignment = NSTextAlignmentCenter;
        errorLabel.numberOfLines = 0;
        [simpleVC.view addSubview:errorLabel];

        simpleWindow.rootViewController = simpleVC;

        // Force display with minimal complexity
        [simpleWindow makeKeyAndVisible];

        // NSLog(@"🎨 Simple nuclear window created - should be visible immediately");
      } else {
        UIWindow* existingWindow = windows.firstObject;

        // Create a full-screen overlay view
        UIView* errorOverlay = [[UIView alloc] initWithFrame:existingWindow.bounds];
        errorOverlay.backgroundColor = [UIColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:0.95];
        errorOverlay.tag = 99999;  // Unique tag for identification

        // Add error text to the overlay
        UILabel* errorLabel = [[UILabel alloc] init];
        errorLabel.text =
            [NSString stringWithFormat:@"⚠️ JavaScript Error\n\n%@\n\nFix the error and save "
                                       @"your changes to continue.",
                                       [NSString stringWithUTF8String:message.c_str()]];
        errorLabel.textColor = [UIColor whiteColor];
        errorLabel.font = [UIFont boldSystemFontOfSize:16];
        errorLabel.textAlignment = NSTextAlignmentCenter;
        errorLabel.numberOfLines = 0;
        errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [errorOverlay addSubview:errorLabel];

        // Center the label
        [NSLayoutConstraint activateConstraints:@[
          [errorLabel.centerXAnchor constraintEqualToAnchor:errorOverlay.centerXAnchor],
          [errorLabel.centerYAnchor constraintEqualToAnchor:errorOverlay.centerYAnchor],
          [errorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:errorOverlay.leadingAnchor
                                                                constant:20],
          [errorLabel.trailingAnchor constraintLessThanOrEqualToAnchor:errorOverlay.trailingAnchor
                                                              constant:-20]
        ]];

        // Add tap gesture to dismiss
        UITapGestureRecognizer* tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:nil
                                                                                     action:nil];
        [tapGesture addTarget:errorOverlay action:@selector(removeFromSuperview)];
        [errorOverlay addGestureRecognizer:tapGesture];

        // Remove any previous error overlay
        for (UIView* subview in existingWindow.subviews) {
          if (subview.tag == 99999) {
            [subview removeFromSuperview];
          }
        }

        // Add the overlay to the existing window
        [existingWindow addSubview:errorOverlay];
        [existingWindow bringSubviewToFront:errorOverlay];

        // NSLog(@"🎨 Error overlay added to existing window successfully!");
      }
    }

    // NSLog(@"🎨 Beautiful NativeScript-branded error modal displayed successfully!");

  } @catch (NSException* exception) {
    // NSLog(@"🎨 ERROR: Failed to display error modal: %@", exception);
    // NSLog(@"🎨 Attempting fallback display method...");

    // Fallback: Try to show an alert instead
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:@"⚠️ JavaScript Error"
                                            message:[NSString stringWithUTF8String:message.c_str()]
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
                   //  NSLog(@"🎨 Error modal UI fully rendered and stable - app should stay alive
                   //  now");

                   // Force the main run loop to process any pending events to keep the app
                   // responsive
                   CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
                 });
}
}
