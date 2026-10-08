#include "MethodCallProfiler.h"

#include <algorithm>
#include <mutex>
#include <sstream>
#include <unordered_map>
#include <vector>

#include "AOTCalls.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

std::atomic<bool> MethodCallProfiler::enabled_{false};

namespace {

struct MethodProfile {
  std::string className;
  std::string selectorName;
  std::string returnType;
  std::vector<std::string> argTypes;
  uint64_t count = 0;
  bool isStatic = false;
};

// Leaked so exit()'s static destructors cannot run under a worker thread that
// is still recording.
std::mutex& profileMutex = *new std::mutex();
std::unordered_map<std::string, MethodProfile>& profiles =
    *new std::unordered_map<std::string, MethodProfile>();

std::string EncodingToTypeName(const TypeEncoding* enc) {
  switch (enc->type) {
    case BinaryTypeEncodingType::VoidEncoding:
      return "void";
    case BinaryTypeEncodingType::BoolEncoding:
      return "BOOL";
    case BinaryTypeEncodingType::IdEncoding:
      return "id";
    case BinaryTypeEncodingType::InterfaceDeclarationReference:
      return enc->details.interfaceDeclarationReference.name.valuePtr();
    case BinaryTypeEncodingType::InstanceTypeEncoding:
      return "instancetype";
    case BinaryTypeEncodingType::SelectorEncoding:
      return "SEL";
    case BinaryTypeEncodingType::ClassEncoding:
      return "Class";
    case BinaryTypeEncodingType::IntEncoding:
      return "int";
    case BinaryTypeEncodingType::UIntEncoding:
      return "uint";
    case BinaryTypeEncodingType::LongEncoding:
      return "long";
    case BinaryTypeEncodingType::ULongEncoding:
      return "ulong";
    case BinaryTypeEncodingType::LongLongEncoding:
      return "longlong";
    case BinaryTypeEncodingType::ULongLongEncoding:
      return "ulonglong";
    case BinaryTypeEncodingType::FloatEncoding:
      return "float";
    case BinaryTypeEncodingType::DoubleEncoding:
      return "double";
    case BinaryTypeEncodingType::CharEncoding:
      return "char";
    case BinaryTypeEncodingType::UCharEncoding:
      return "uchar";
    case BinaryTypeEncodingType::ShortEncoding:
      return "short";
    case BinaryTypeEncodingType::UShortEncoding:
      return "ushort";
    case BinaryTypeEncodingType::UnicharEncoding:
      return "unichar";
    case BinaryTypeEncodingType::StructDeclarationReference:
      return enc->details.declarationReference.name.valuePtr();
    case BinaryTypeEncodingType::PointerEncoding:
    case BinaryTypeEncodingType::CStringEncoding:
    case BinaryTypeEncodingType::IncompleteArrayEncoding:
      return "pointer";
    case BinaryTypeEncodingType::BlockEncoding:
    case BinaryTypeEncodingType::FunctionPointerEncoding:
      return "block";
    case BinaryTypeEncodingType::ProtocolEncoding:
      return "id";
    default:
      return "";
  }
}

// Caller holds profileMutex.
std::vector<const MethodProfile*> SortedProfiles(int topN) {
  std::vector<const MethodProfile*> sorted;
  sorted.reserve(profiles.size());
  for (const auto& pair : profiles) {
    sorted.push_back(&pair.second);
  }
  std::sort(sorted.begin(), sorted.end(),
            [](const MethodProfile* a, const MethodProfile* b) { return a->count > b->count; });
  if (topN > 0 && (int)sorted.size() > topN) {
    sorted.resize(topN);
  }
  return sorted;
}

int TopNArgument(const FunctionCallbackInfo<Value>& info) {
  if (info.Length() > 0 && info[0]->IsNumber()) {
    return (int)tns::ToNumber(info.GetIsolate(), info[0]);
  }
  return 50;
}

}  // namespace

void MethodCallProfiler::Enable() { enabled_.store(true, std::memory_order_relaxed); }

void MethodCallProfiler::Disable() { enabled_.store(false, std::memory_order_relaxed); }

void MethodCallProfiler::Reset() {
  std::lock_guard<std::mutex> lock(profileMutex);
  profiles.clear();
}

void MethodCallProfiler::RecordCall(const std::string& className, const MethodMeta* meta,
                                    bool isStatic) {
  const char* selector = meta->selectorAsString();
  std::string key = className;
  key += isStatic ? "\t+\t" : "\t-\t";
  key += selector;

  std::lock_guard<std::mutex> lock(profileMutex);
  auto it = profiles.find(key);
  if (it != profiles.end()) {
    it->second.count++;
    return;
  }

  MethodProfile profile;
  profile.className = className;
  profile.selectorName = selector;
  profile.count = 1;
  profile.isStatic = isStatic;

  const auto* encodings = meta->encodings();
  const TypeEncoding* enc = encodings->first();
  std::string returnName = EncodingToTypeName(enc);
  profile.returnType = returnName.empty() ? "?" : returnName;

  int paramCount = encodings->count - 1;
  for (int i = 0; i < paramCount; i++) {
    enc = enc->next();
    std::string argName = EncodingToTypeName(enc);
    profile.argTypes.push_back(argName.empty() ? "?" : argName);
  }

  profiles.emplace(std::move(key), std::move(profile));
}

void MethodCallProfiler::JSStart(const FunctionCallbackInfo<Value>& info) { Enable(); }

void MethodCallProfiler::JSStop(const FunctionCallbackInfo<Value>& info) { Disable(); }

void MethodCallProfiler::JSReset(const FunctionCallbackInfo<Value>& info) { Reset(); }

void MethodCallProfiler::JSReport(const FunctionCallbackInfo<Value>& info) {
  int topN = TopNArgument(info);

  std::ostringstream out;
  {
    std::lock_guard<std::mutex> lock(profileMutex);
    auto sorted = SortedProfiles(topN);
    out << "Top " << sorted.size() << " method calls:\n";
    for (size_t i = 0; i < sorted.size(); i++) {
      const auto& p = *sorted[i];
      out << "  " << (i + 1) << ". " << p.className << " " << (p.isStatic ? "+" : "-") << "["
          << p.selectorName << "] " << p.returnType << "(";
      for (size_t j = 0; j < p.argTypes.size(); j++) {
        if (j > 0) out << ", ";
        out << p.argTypes[j];
      }
      out << ") - " << p.count << " calls\n";
    }
  }

  info.GetReturnValue().Set(tns::ToV8String(info.GetIsolate(), out.str()));
}

void MethodCallProfiler::JSAOTConfig(const FunctionCallbackInfo<Value>& info) {
  int topN = TopNArgument(info);
  auto isUnsupported = [](const std::string& t) {
    return t == "?" || t == "pointer" || t == "block";
  };

  std::ostringstream out;
  {
    std::lock_guard<std::mutex> lock(profileMutex);
    auto sorted = SortedProfiles(topN);
    out << "[\n";
    bool first = true;
    for (const auto* p : sorted) {
      bool hasUnsupportedType = isUnsupported(p->returnType);
      for (const auto& a : p->argTypes) {
        hasUnsupportedType = hasUnsupportedType || isUnsupported(a);
      }
      if (hasUnsupportedType) continue;

      if (!first) out << ",\n";
      first = false;

      out << "  { \"class\": \"" << p->className << "\", \"selector\": \"" << p->selectorName
          << "\", \"ret\": \"" << p->returnType << "\", \"args\": [";
      for (size_t j = 0; j < p->argTypes.size(); j++) {
        if (j > 0) out << ", ";
        out << "\"" << p->argTypes[j] << "\"";
      }
      out << "]";
      if (p->isStatic) {
        out << ", \"static\": true";
      }
      out << " }";
    }
    out << "\n]";
  }

  info.GetReturnValue().Set(tns::ToV8String(info.GetIsolate(), out.str()));
}

void MethodCallProfiler::JSAOTStats(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  Local<Object> stats = Object::New(isolate);
  bool success = stats
                     ->Set(context, tns::ToV8String(isolate, "served"),
                           Number::New(isolate, (double)aot::ServedCallCount()))
                     .FromMaybe(false) &&
                 stats
                     ->Set(context, tns::ToV8String(isolate, "declined"),
                           Number::New(isolate, (double)aot::DeclinedCallCount()))
                     .FromMaybe(false);
  if (success) {
    info.GetReturnValue().Set(stats);
  }
}

MaybeLocal<Object> MethodCallProfiler::GetExports(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  EscapableHandleScope scope(isolate);
  Local<Object> profiler = Object::New(isolate);
  const std::pair<const char*, FunctionCallback> methods[] = {
      {"start", JSStart},   {"stop", JSStop},           {"reset", JSReset},
      {"report", JSReport}, {"aotConfig", JSAOTConfig}, {"aotStats", JSAOTStats},
  };
  for (const auto& [name, callback] : methods) {
    Local<v8::Function> function;
    if (!v8::Function::New(context, callback).ToLocal(&function) ||
        !profiler->Set(context, tns::ToV8String(isolate, name), function).FromMaybe(false)) {
      return MaybeLocal<Object>();
    }
  }

  Local<Object> exports = Object::New(isolate);
  if (!exports->Set(context, tns::ToV8String(isolate, "profiler"), profiler).FromMaybe(false)) {
    return MaybeLocal<Object>();
  }
  return scope.Escape(exports);
}

}  // namespace tns
