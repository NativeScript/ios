#ifndef Common_h
#define Common_h

#include <type_traits>
#include <typeinfo>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"

// FIXME: Move these to a secondary header?
#include "v8-cppgc.h"
#include "cppgc/allocation.h"
#include "cppgc/type-traits.h"
#pragma clang diagnostic pop

#include <iostream>
namespace tns {

// FIXME(caitp): Move me to a new file
static constexpr uint32_t kExternalDataHeader = 0x45585400;
enum class ExternalDataType {
    ClassBuilder,
};
class ExternalData {
public:
    ExternalData(ExternalDataType type)
    : header(kExternalDataHeader)
    , type_(type) {}
    virtual ~ExternalData() = default;
    bool IsExternalData() const { return header == kExternalDataHeader; }
    bool IsClassBuilderData() const { assert(IsExternalData()); return type_ == ExternalDataType::ClassBuilder; }
    
private:
    uint32_t header;
    ExternalDataType type_;
};


#define ALLOCATION_HANDLE_FOR_ISOLATE(isolate) (isolate->GetCppHeap()->GetAllocationHandle())

template <typename T>
struct HasClassNameMethod {
private:
    template <typename U>
    static auto test(int) -> decltype(U::ClassName(), std::true_type{});
    
    template <typename U>
    static std::false_type test(...);
    
public:
    static constexpr bool value = decltype(test<T>(0))::value;
};

template <typename T>
typename std::enable_if<HasClassNameMethod<T>::value, const char*>::type
InvokeClassName() {
    return T::ClassName();
}

template <typename T>
typename std::enable_if<!HasClassNameMethod<T>::value, const char*>::type
InvokeClassName() {
    return "Unknown";
}

template <typename T, typename... Args>
T* MakeGarbageCollected(v8::Isolate* isolate, Args&&... args) {
    T* p = nullptr;
    if constexpr (std::is_constructible_v<T, v8::Isolate*, Args&&...>) {
        // Supply the isolate* to the target constructor if it's the first parameter.
        p = cppgc::MakeGarbageCollected<T>(ALLOCATION_HANDLE_FOR_ISOLATE(isolate), isolate, std::forward<Args>(args)...);
    } else {
        p = cppgc::MakeGarbageCollected<T>(ALLOCATION_HANDLE_FOR_ISOLATE(isolate), std::forward<Args>(args)...);
    }
    //std::cout << "MakeGarbageCollected<" << InvokeClassName<T>() << ">() -> (" << (void*)p << ")\n";
    return p;
}

using TracedValue = v8::TracedReference<v8::Value>;
using TracedObject = v8::TracedReference<v8::Object>;

template <typename T>
v8::TracedReference<T> ToTraced(v8::Isolate* isolate, v8::Local<T> local) {
    return v8::TracedReference<T>(isolate, local);
}

template <typename T>
v8::TracedReference<T> ToTraced(v8::Isolate* isolate, v8::PersistentBase<T> persistent) {
    return v8::TracedReference<typename T::ValueType>(isolate, persistent);
}

class CommonPrivate {
private:
    static v8::Local<v8::Object> CreateExtensibleWrapperObject(v8::Isolate*, v8::Local<v8::Context>);
    static inline v8::Local<v8::Object> CreateWrapperObject(v8::Isolate* isolate, v8::Local<v8::Context> context)
    {
        auto result = CreateExtensibleWrapperObject(isolate, context);
        result->SetIntegrityLevel(context, v8::IntegrityLevel::kSealed);
        return result;
    }
    
    template <typename T, typename U>
    friend v8::Local<v8::Object> CreateWrapperFor(v8::Isolate*, v8::Local<v8::Context>, T*);
    template <typename T, typename U>
    friend v8::Local<v8::Object> CreateExtensibleWrapperFor(v8::Isolate*, v8::Local<v8::Context>, T*);
    friend bool IsGarbageCollectedWrapper(v8::Local<v8::Object>);
};

static constexpr uint16_t kGarbageCollectedEmbedderId = 5440;
static constexpr v8::WrapperDescriptor kGarbageCollectedWrapperDescriptor {
    0, /* wrappable_type_index, field which holds Smi-encoded kGarbageCollectedEmbedderId */
    1, /* wrappable_instance_index, field which holds a BaseDataWrapper* or other GC'd type */
    kGarbageCollectedEmbedderId,
};
static constexpr int kMinGarbageCollectedEmbedderFields = 2;
static_assert(kMinGarbageCollectedEmbedderFields >=
              std::max(
                       kGarbageCollectedWrapperDescriptor.wrappable_type_index,
                       kGarbageCollectedWrapperDescriptor.wrappable_instance_index));

template <typename T, typename = std::enable_if_t<cppgc::IsGarbageCollectedOrMixinTypeV<T>>>
static inline bool AttachGarbageCollectedWrapper(v8::Local<v8::Object> object, T* p)
{
    //std::cout << "Attaching GC Wrapper" << InvokeClassName<T>() << " (" << (void*)p << ") to v8 object " << *object << "\n";
    alignas(2) static const uint16_t embedder_id { kGarbageCollectedEmbedderId };
    
    if (object->InternalFieldCount() < kMinGarbageCollectedEmbedderFields)
        return false;
    
    auto desc = kGarbageCollectedWrapperDescriptor;
    object->SetAlignedPointerInInternalField(desc.wrappable_type_index, (void*)&embedder_id);
    object->SetAlignedPointerInInternalField(desc.wrappable_instance_index, p);
    
    return true;
}

static inline void DetachGarbageCollectedWrapper(v8::Local<v8::Object> object)
{
    if (object->InternalFieldCount() < kMinGarbageCollectedEmbedderFields)
        return;
    
    auto desc = kGarbageCollectedWrapperDescriptor;
    object->SetAlignedPointerInInternalField(desc.wrappable_type_index, nullptr);
    object->SetAlignedPointerInInternalField(desc.wrappable_instance_index, nullptr);
}

inline bool IsGarbageCollectedWrapper(v8::Local<v8::Object> object)
{
    static auto test = [](void* p) {
        if (!p) return false;
        return *static_cast<uint16_t*>(p) == kGarbageCollectedEmbedderId;
    };
    auto desc = kGarbageCollectedWrapperDescriptor;
    return !object.IsEmpty() && object->InternalFieldCount() >= kMinGarbageCollectedEmbedderFields && test(object->GetAlignedPointerFromInternalField(desc.wrappable_type_index));
}

inline bool IsGarbageCollectedWrapper(v8::Local<v8::Value> object)
{
    if (!object->IsObject())
        return false;
    return IsGarbageCollectedWrapper(object.As<v8::Object>());
}

template <typename T, typename = std::enable_if_t<cppgc::IsGarbageCollectedOrMixinTypeV<T>>>
v8::Local<v8::Object> CreateWrapperFor(v8::Isolate* isolate, v8::Local<v8::Context> context, T* ptr)
{
    auto result = CommonPrivate::CreateWrapperObject(isolate, context);
    AttachGarbageCollectedWrapper(result, ptr);
    return result;
}

template <typename T, typename = std::enable_if_t<cppgc::IsGarbageCollectedOrMixinTypeV<T>>>
v8::Local<v8::Object> CreateWrapperFor(v8::Local<v8::Context> context, T* ptr)
{
    return CreateWrapperFor<T>(context->GetIsolate(), context, ptr);
}

template <typename T, typename = std::enable_if_t<cppgc::IsGarbageCollectedOrMixinTypeV<T>>>
v8::Local<v8::Object> CreateWrapperFor(v8::Isolate* isolate, T* ptr)
{
    return CreateWrapperFor<T>(isolate, isolate->GetCurrentContext(), ptr);
}

template <typename T, typename = std::enable_if_t<cppgc::IsGarbageCollectedOrMixinTypeV<T>>>
v8::Local<v8::Object> CreateExtensibleWrapperFor(v8::Isolate* isolate, v8::Local<v8::Context> context, T* ptr)
{
    auto result = CommonPrivate::CreateExtensibleWrapperObject(isolate, context);
    AttachGarbageCollectedWrapper(result, ptr);
    return result;
}

template <typename T, typename = std::enable_if_t<cppgc::IsGarbageCollectedOrMixinTypeV<T>>>
v8::Local<v8::Object> CreateExtensibleWrapperFor(v8::Local<v8::Context> context, T* ptr)
{
    return CreateExtensibleWrapperFor<T>(context->GetIsolate(), context, ptr);
}

template <typename T, typename = std::enable_if_t<cppgc::IsGarbageCollectedOrMixinTypeV<T>>>
v8::Local<v8::Object> CreateExtensibleWrapperFor(v8::Isolate* isolate, T* ptr)
{
    return CreateExtensibleWrapperFor<T>(isolate, isolate->GetCurrentContext(), ptr);
}

template <typename T, typename = std::enable_if_t<cppgc::IsGarbageCollectedOrMixinTypeV<T>>>
T* ExtractWrapper(v8::Local<v8::Object> object)
{
    if (object.IsEmpty() || !IsGarbageCollectedWrapper(object))
        return nullptr;
    
    auto desc = kGarbageCollectedWrapperDescriptor;
    return static_cast<T*>(object->GetAlignedPointerFromInternalField(desc.wrappable_instance_index));
}

template <typename T, typename = std::enable_if_t<cppgc::IsGarbageCollectedOrMixinTypeV<T>>>
T* ExtractWrapper(v8::Local<v8::Value> value)
{
    if (value.IsEmpty() || !value->IsObject())
        return nullptr;
    auto object = value.As<v8::Object>();
    if (!IsGarbageCollectedWrapper(object))
        return nullptr;
    
    auto desc = kGarbageCollectedWrapperDescriptor;
    return static_cast<T*>(object->GetAlignedPointerFromInternalField(desc.wrappable_instance_index));
}
}
#include <sstream>
namespace tns {
static inline void PrintProperties(const v8::Local<v8::Object>& obj) {
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  v8::HandleScope scope(isolate);

  v8::Local<v8::Array> properties = obj->GetPropertyNames(isolate->GetCurrentContext()).ToLocalChecked();

  std::vector<std::string> propertyNames;
  for (uint32_t i = 0; i < properties->Length(); ++i) {
    v8::Local<v8::Value> key = properties->Get(isolate->GetCurrentContext(), i).ToLocalChecked();
    v8::String::Utf8Value utf8Value(isolate, key);

    propertyNames.push_back(*utf8Value);
  }

  std::stringstream ss;
  ss << "[ ";
  for (const std::string& propertyName : propertyNames) {
    ss << propertyName << ",\n";
  }
  ss << "]" << std::endl;

  std::cout << ss.str();
  std::cout.flush();
}

}

#endif /* Common_h */
