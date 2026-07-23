#include "InlineFunctions.h"

#include "BuiltinLoader.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

void InlineFunctions::Init(Local<Context> context) {
  Isolate* isolate = context->GetIsolate();

  Local<Value> result;
  if (!BuiltinLoader::RunBuiltin(context, BuiltinId::kInlineFunctions)
           .ToLocal(&result)) {
    tns::Assert(false, isolate);
  }
}

bool InlineFunctions::IsGlobalFunction(std::string name) {
  return name == "CGPointMake" || name == "CGRectMake" ||
         name == "CGSizeMake" || name == "UIEdgeInsetsMake" ||
         name == "NSMakeRange" || name == "__decorate" || name == "__param" ||
         name == "ObjCClass" || name == "ObjCMethod" || name == "ObjC" ||
         name == "ObjCParam" || name == "__tsEnum";
}

}  // namespace tns
