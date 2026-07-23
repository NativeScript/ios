#include "TSHelpers.h"

#include <string>

#include "BuiltinLoader.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

void TSHelpers::Init(Local<Context> context) {
  // The purpose of this script is to handle the "new" operator when extending
  // native classes:
  //
  // var InheritingClass = (function (_super) {
  //     __extends(InheritingClass, _super);
  //     function InheritingClass() {
  //         return _super !== null && _super.apply(this, arguments) || this; //
  //         <---- _super.apply and _super.call methods will invoke the original
  //         .extend() method on the derived class
  //     }
  //     return InheritingClass;
  // }(BaseClass));
  // var obj = new InheritingClass();

  Isolate* isolate = context->GetIsolate();
  TryCatch tc(isolate);
  Local<Value> result;
  if (!BuiltinLoader::RunBuiltin(context, BuiltinId::kTsHelpers)
           .ToLocal(&result) &&
      tc.HasCaught()) {
    tns::LogError(isolate, tc);
    tns::Assert(false, isolate);
  }
}

}  // namespace tns
