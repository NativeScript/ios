#include "MethodCallProfiler.h"
#include <algorithm>
#include <mutex>
#include <sstream>
#include <unordered_map>
#include <vector>
#include "Helpers.h"

using namespace v8;

namespace tns {

std::atomic<bool> MethodCallProfiler::enabled_{false};

struct MethodProfile {
  std::string className;
  std::string selectorName;
  std::string returnType;
  std::vector<std::string> argTypes;
  uint64_t count = 0;
  bool isStatic = false;
};

static std::mutex sProfileMutex;
static std::unordered_map<std::string, MethodProfile> sProfiles;

static std::string EncodingToTypeName(const TypeEncoding* enc) {
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
      return "ushort";
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

void MethodCallProfiler::Enable() { enabled_.store(true, std::memory_order_relaxed); }

void MethodCallProfiler::Disable() { enabled_.store(false, std::memory_order_relaxed); }

void MethodCallProfiler::Reset() {
  std::lock_guard<std::mutex> lock(sProfileMutex);
  sProfiles.clear();
}

void MethodCallProfiler::RecordCall(const std::string& className, const MethodMeta* meta,
                                    bool isStatic) {
  const char* sel = meta->selectorAsString();
  std::string key = className + "\t" + (isStatic ? "+" : "-") + "\t" + sel;

  std::lock_guard<std::mutex> lock(sProfileMutex);
  auto it = sProfiles.find(key);
  if (it != sProfiles.end()) {
    it->second.count++;
    return;
  }

  MethodProfile profile;
  profile.className = className;
  profile.selectorName = sel;
  profile.count = 1;
  profile.isStatic = isStatic;

  const auto* encodings = meta->encodings();
  const TypeEncoding* enc = encodings->first();
  std::string retName = EncodingToTypeName(enc);
  profile.returnType = retName.empty() ? "?" : retName;

  int paramCount = encodings->count - 1;
  for (int i = 0; i < paramCount; i++) {
    enc = enc->next();
    std::string argName = EncodingToTypeName(enc);
    profile.argTypes.push_back(argName.empty() ? "?" : argName);
  }

  sProfiles.emplace(key, std::move(profile));
}

static std::vector<const MethodProfile*> GetSortedProfiles(int topN) {
  std::vector<const MethodProfile*> sorted;
  sorted.reserve(sProfiles.size());
  for (const auto& pair : sProfiles) {
    sorted.push_back(&pair.second);
  }
  std::sort(sorted.begin(), sorted.end(),
            [](const MethodProfile* a, const MethodProfile* b) { return a->count > b->count; });
  if (topN > 0 && (int)sorted.size() > topN) {
    sorted.resize(topN);
  }
  return sorted;
}

void MethodCallProfiler::JSStart(const FunctionCallbackInfo<Value>& info) { Enable(); }

void MethodCallProfiler::JSStop(const FunctionCallbackInfo<Value>& info) { Disable(); }

void MethodCallProfiler::JSReset(const FunctionCallbackInfo<Value>& info) { Reset(); }

void MethodCallProfiler::JSReport(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  int topN = 50;
  if (info.Length() > 0 && info[0]->IsNumber()) {
    topN = (int)tns::ToNumber(isolate, info[0]);
  }

  std::lock_guard<std::mutex> lock(sProfileMutex);
  auto sorted = GetSortedProfiles(topN);

  std::ostringstream out;
  out << "Top " << sorted.size() << " method calls:\n";
  for (size_t i = 0; i < sorted.size(); i++) {
    const auto& p = *sorted[i];
    out << "  " << (i + 1) << ". " << p.className << " " << (p.isStatic ? "+" : "-") << "["
        << p.selectorName << "] " << p.returnType << "(";
    for (size_t j = 0; j < p.argTypes.size(); j++) {
      if (j > 0) out << ", ";
      out << p.argTypes[j];
    }
    out << ") — " << p.count << " calls\n";
  }

  info.GetReturnValue().Set(tns::ToV8String(isolate, out.str()));
}

void MethodCallProfiler::JSAOTConfig(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  int topN = 50;
  if (info.Length() > 0 && info[0]->IsNumber()) {
    topN = (int)tns::ToNumber(isolate, info[0]);
  }

  std::lock_guard<std::mutex> lock(sProfileMutex);
  auto sorted = GetSortedProfiles(topN);

  std::ostringstream out;
  out << "[\n";
  bool first = true;
  for (const auto* p : sorted) {
    auto isUnsupported = [](const std::string& t) {
      return t == "?" || t == "pointer" || t == "block";
    };
    bool hasUnknownType = isUnsupported(p->returnType);
    for (const auto& a : p->argTypes) {
      if (isUnsupported(a)) hasUnknownType = true;
    }
    if (hasUnknownType) continue;

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

  info.GetReturnValue().Set(tns::ToV8String(isolate, out.str()));
}

void MethodCallProfiler::RegisterJSAPI(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
  Local<ObjectTemplate> profiler = ObjectTemplate::New(isolate);
  profiler->Set(tns::ToV8String(isolate, "start"), FunctionTemplate::New(isolate, JSStart));
  profiler->Set(tns::ToV8String(isolate, "stop"), FunctionTemplate::New(isolate, JSStop));
  profiler->Set(tns::ToV8String(isolate, "reset"), FunctionTemplate::New(isolate, JSReset));
  profiler->Set(tns::ToV8String(isolate, "report"), FunctionTemplate::New(isolate, JSReport));
  profiler->Set(tns::ToV8String(isolate, "aotConfig"), FunctionTemplate::New(isolate, JSAOTConfig));
  globalTemplate->Set(tns::ToV8String(isolate, "__native_call_profiler"), profiler);
}

}  // namespace tns
