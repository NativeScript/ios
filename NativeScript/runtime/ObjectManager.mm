#include <CoreFoundation/CoreFoundation.h>
#include <sstream>
#include "ObjectManager.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Caches.h"
#import <malloc/malloc.h>
#import "Runtime.h"
#import <mach/mach.h>

using namespace v8;
using namespace std;

namespace tns {

static Class NSTimerClass = objc_getClass("NSTimer");

void ObjectManager::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
    globalTemplate->Set(tns::ToV8String(isolate, "__releaseNativeCounterpart"), FunctionTemplate::New(isolate, ReleaseNativeCounterpartCallback));
}

size_t get_current_memory_usage() {
    struct task_basic_info info;
      mach_msg_type_number_t size = TASK_BASIC_INFO_COUNT;
      kern_return_t kerr = task_info(mach_task_self(),
                                     TASK_BASIC_INFO,
                                     (task_info_t)&info,
                                     &size);
      if( kerr == KERN_SUCCESS ) {
        // NSLog(@"Memory in use (in bytes): %lu", info.resident_size);
         // NSLog(@"Memory in use (in MiB): %f", ((float)info.resident_size / 1048576));
      } else {
        NSLog(@"Error with task_info(): %s", mach_error_string(kerr));
          return -1;
      }
    return info.resident_size;
}

bool enable_stuff = true;

void updateV8Memory(Isolate* isolate) {
    if(!enable_stuff) return;
    static long current_memory = get_current_memory_usage();
    long last_mem = current_memory;
    current_memory = get_current_memory_usage();
    if(current_memory == -1 || last_mem == -1 || last_mem == current_memory) {
        // isolate->AdjustAmountOfExternalAllocatedMemory(5* 1024 * 1024);
        return;
    }
    long delta = current_memory - last_mem;
    NSLog(@"adjust by %ld", delta);
    isolate->AdjustAmountOfExternalAllocatedMemory(delta);
    if(delta > 20 * 1024 * 1024){
        NSLog(@"Too much memory allocated, inform v8 %ld", delta);
        // Runtime::GetCurrentRuntime()->GetIsolate()->LowMemoryNotification();
    }
}
void ActiveSenseTimerCallback(CFRunLoopTimerRef timer, void *info)
{
  // NSLog(@"Timeout");
  CFRunLoopTimerContext TimerContext;
  TimerContext.version = 0;

  CFRunLoopTimerGetContext(timer, &TimerContext);
  // uncomment if you want to use the timer
    // updateV8Memory(Runtime::GetCurrentRuntime()->GetIsolate());
    // Runtime::GetCurrentRuntime()->GetIsolate()->SetGetExternallyAllocatedMemoryInBytesCallback(&duh);
    // Runtime::GetCurrentRuntime()->GetIsolate()->LowMemoryNotification();
    // bool __unused ret = Runtime::GetCurrentRuntime()->GetIsolate()->IdleNotificationDeadline(Runtime::GetCurrentRuntime()->GetPlatform()->MonotonicallyIncreasingTime() + 1.0);
    // if(!ret)
    // NSLog(@"------------------------------------Timeout %d", ret);
    //Runtime::GetCurrentRuntime()->GetIsolate()->memory;
  // ((cClass *)TimerContext.info)->Timeout();
}

void ObjectManager::updateV8memory2() {
    updateV8Memory(Runtime::GetCurrentRuntime()->GetIsolate());
}

std::shared_ptr<Persistent<Value>> ObjectManager::Register(Local<Context> context, const Local<Value> obj) {
    // context->GetIsolate()->AdjustAmountOfExternalAllocatedMemory(5 * 1024 * 1024);
    // context->GetIsolate()->AdjustAmountOfExternalAllocatedMemory(100);
    static bool started = false;
    if(!started) {
        started = true;
        
    
    CFTimeInterval TIMER_INTERVAL = 1;
        get_current_memory_usage();
        CFRunLoopTimerContext TimerContext = {0, context->GetIsolate(), NULL, NULL, NULL};
        CFAbsoluteTime FireTime = CFAbsoluteTimeGetCurrent() + TIMER_INTERVAL;
        auto __unused mTimer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                      FireTime,
                                      1, 0, 0,
                                      ActiveSenseTimerCallback,
                                      &TimerContext);
    
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), mTimer, kCFRunLoopCommonModes);
    }

        
    
    Isolate* isolate = context->GetIsolate();
    std::shared_ptr<Persistent<Value>> objectHandle = std::make_shared<Persistent<Value>>(isolate, obj);
    ObjectWeakCallbackState* state = new ObjectWeakCallbackState(objectHandle);
    objectHandle->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);
    updateV8Memory(isolate);
    return objectHandle;
}

void ObjectManager::FinalizerCallback(const WeakCallbackInfo<ObjectWeakCallbackState>& data) {
    ObjectWeakCallbackState* state = data.GetParameter();
    Isolate* isolate = data.GetIsolate();
    Local<Value> value = state->target_->Get(isolate);
    bool disposed = ObjectManager::DisposeValue(isolate, value);

    if (disposed) {
        // isolate->AdjustAmountOfExternalAllocatedMemory(-1 * 5 * 1024 * 1024);
        state->target_->Reset();
        delete state;
    } else {
        state->target_->ClearWeak();
        state->target_->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);
    }
    updateV8Memory(isolate);
}

bool ObjectManager::DisposeValue(Isolate* isolate, Local<Value> value) {
    if (value.IsEmpty() || value->IsNullOrUndefined() || !value->IsObject()) {
        return true;
    }

    Local<Object> obj = value.As<Object>();
    if (obj->InternalFieldCount() > 1) {
        Local<Value> superValue = obj->GetInternalField(1);
        if (!superValue.IsEmpty() && superValue->IsString()) {
            // Do not dispose the ObjCWrapper contained in a "super" instance
            return true;
        }
    }

    BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
    if (wrapper == nullptr) {
        tns::SetValue(isolate, obj, nullptr);
        return true;
    }

    if (wrapper->IsGcProtected()) {
        return false;
    }

    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    switch (wrapper->Type()) {
        case WrapperType::Struct: {
            StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
            void* data = structWrapper->Data();

            std::shared_ptr<Persistent<Value>> poParentStruct = structWrapper->Parent();
            if (poParentStruct != nullptr) {
                Local<Value> parentStruct = poParentStruct->Get(isolate);
                BaseDataWrapper* parentWrapper = tns::GetValue(isolate, parentStruct);
                if (parentWrapper != nullptr && parentWrapper->Type() == WrapperType::Struct) {
                    StructWrapper* parentStructWrapper = static_cast<StructWrapper*>(parentWrapper);
                    parentStructWrapper->DecrementChildren();
                }
            } else {
                if (structWrapper->ChildCount() == 0) {
                    std::pair<void*, std::string> key = std::make_pair(data, structWrapper->StructInfo().Name());
                    cache->StructInstances.erase(key);
                    std::free(data);
                } else {
                    return false;
                }
            }
            break;
        }
        case WrapperType::ObjCObject: {
            ObjCDataWrapper* objCObjectWrapper = static_cast<ObjCDataWrapper*>(wrapper);
            // NSLog(@"size of myObject: %zd", malloc_size(objCObjectWrapper->Data()));
            // isolate->AdjustAmountOfExternalAllocatedMemory(-1 * malloc_size(objCObjectWrapper->Data()));
            auto retainCount = CFGetRetainCount((__bridge CFTypeRef)objCObjectWrapper->Data());
            if(retainCount > 2) {
                // NSLog(@"Retain count is %ld", retainCount);
                // return false;
            }
            id target = objCObjectWrapper->Data();
            if (target != nil) {
                cache->Instances.erase(target);
                [target release];
            }
            break;
        }
        case WrapperType::UnmanagedType: {
            UnmanagedTypeWrapper* unmanagedTypeWrapper = static_cast<UnmanagedTypeWrapper*>(wrapper);
            if (unmanagedTypeWrapper != nullptr) {
                delete unmanagedTypeWrapper;
            }
            break;
        }
        case WrapperType::Block: {
            BlockWrapper* blockWrapper = static_cast<BlockWrapper*>(wrapper);
            std::free(blockWrapper->Block());
            break;
        }
        case WrapperType::Reference: {
            ReferenceWrapper* referenceWrapper = static_cast<ReferenceWrapper*>(wrapper);
            if (referenceWrapper->Data() != nullptr) {
                referenceWrapper->SetData(nullptr);
                referenceWrapper->SetEncoding(nullptr);
            }

            break;
        }
        case WrapperType::Pointer: {
            PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
            if (pointerWrapper->Data() != nullptr) {
                cache->PointerInstances.erase(pointerWrapper->Data());

                if (pointerWrapper->IsAdopted()) {
                    std::free(pointerWrapper->Data());
                    pointerWrapper->SetData(nullptr);
                }
            }
            break;
        }
        case WrapperType::FunctionReference: {
            FunctionReferenceWrapper* funcWrapper = static_cast<FunctionReferenceWrapper*>(wrapper);
            std::shared_ptr<Persistent<Value>> func = funcWrapper->Function();
            if (func != nullptr) {
                func->Reset();
            }
            break;
        }
        case WrapperType::AnonymousFunction: {
            break;
        }
        case WrapperType::ExtVector: {
            ExtVectorWrapper* extVectorWrapper = static_cast<ExtVectorWrapper*>(wrapper);
            void* data = extVectorWrapper->Data();
            if (data) {
                std::free(data);
            }
        }
        case WrapperType::Worker: {
            WorkerWrapper* worker = static_cast<WorkerWrapper*>(wrapper);
            if (worker->IsRunning()) {
                return false;
            } else {
                return true;
            }
        }

        default:
            break;
    }

    delete wrapper;
    wrapper = nullptr;
    tns::DeleteValue(isolate, obj);
    return true;
}

void ObjectManager::ReleaseNativeCounterpartCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();

    if (info.Length() != 1) {
        std::ostringstream errorStream;
        errorStream << "Actual arguments count: \"" << info.Length() << "\". Expected: \"1\".";
        std::string errorMessage = errorStream.str();
        Local<Value> error = Exception::Error(tns::ToV8String(isolate, errorMessage));
        isolate->ThrowException(error);
        return;
    }

    Local<Value> value = info[0];
    BaseDataWrapper* wrapper = tns::GetValue(isolate, value);

    if (wrapper == nullptr) {
        std::string arg0 = tns::ToString(isolate, info[0]);
        std::ostringstream errorStream;
        errorStream << arg0 << " is an object which is not a native wrapper.";
        std::string errorMessage = errorStream.str();
        Local<Value> error = Exception::Error(tns::ToV8String(isolate, errorMessage));
        isolate->ThrowException(error);
        return;
    }

    if (wrapper->Type() != WrapperType::ObjCObject) {
        return;
    }

    ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
    id data = objcWrapper->Data();
    if (data != nil) {
        std::shared_ptr<Caches> cache = Caches::Get(isolate);
        auto it = cache->Instances.find(data);
        if (it != cache->Instances.end()) {
            ObjectWeakCallbackState* state = it->second->ClearWeak<ObjectWeakCallbackState>();
            if (state != nullptr) {
                delete state;
            }
            cache->Instances.erase(it);
        }

        [data dealloc];

        delete wrapper;
        tns::SetValue(isolate, value.As<Object>(), nullptr);
    }
}

bool ObjectManager::IsInstanceOf(id obj, Class clazz) {
    return [obj isKindOfClass:clazz];
}

long ObjectManager::GetRetainCount(id obj) {
    if (!obj) {
        return 0;
    }

    if (ObjectManager::IsInstanceOf(obj, NSTimerClass)) {
        return 0;
    }

    return CFGetRetainCount(obj);
}

}
