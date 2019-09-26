#include "TSHelpers.h"
#include <string>
#include "Helpers.h"

using namespace v8;

namespace tns {

void TSHelpers::Init(Isolate* isolate) {
    // The purpose of this script is to handle the "new" operator when extending native classes:
    //
    // var InheritingClass = (function (_super) {
    //     __extends(InheritingClass, _super);
    //     function InheritingClass() {
    //         return _super !== null && _super.apply(this, arguments) || this; // <---- _super.apply and _super.call methods will invoke the original .extend() method on the derived class
    //     }
    //     return InheritingClass;
    // }(BaseClass));
    // var obj = new InheritingClass();

    std::string source =
        "(() => {"
        "    var __originalExtends = global.__extends;"
        "    var __extends = (Child, Parent) => {"
        "        var extendingNativeClass = !!Parent.extend && (Parent.extend.toString().indexOf(\"[native code]\") > -1);"
        "        if (!extendingNativeClass) {"
        "            __extends_ts(Child, Parent);"
        "            return;"
        "        }"
        ""
        "        if (Parent.__isPrototypeImplementationObject) {"
        "            throw new Error(\"Can not extend an already extended native object.\");"
        "        }"
        ""
        "        function extend(thiz) {"
        "            var child = thiz.__proto__.__child;"
        "            if (!child.__extended) {"
        "                var parent = thiz.__proto__.__parent;"
        "                child.__extended = parent.extend(child.prototype, {"
        "                    name: child.name,"
        "                    protocols: child.ObjCProtocols || [],"
        "                    exposedMethods: child.ObjCExposedMethods || {}"
        "                });"
        "                child[Symbol.hasInstance] = function (instance) {"
        "                    return instance instanceof this.__extended;"
        "                }"
        "            }"
        "            return child.__extended;"
        "        }"
        ""
        "        Parent.call = function (thiz) {"
        "            var Extended = extend(thiz);"
        "            thiz.__container__ = true;"
        "            if (arguments.length > 1) {"
        "                thiz.__proto__ = new (Function.prototype.bind.apply(Extended, [null].concat(Array.prototype.slice.call(arguments, 1))));"
        "            } else {"
        "                thiz.__proto__ = new Extended()"
        "            }"
        "            return thiz.__proto__;"
        "        };"
        ""
        "        Parent.apply = function (thiz, args) {"
        "            var Extended = extend(thiz);"
        "            thiz.__container__ = true;"
        "            if (args && args.length > 0) {"
        "                thiz.__proto__ = new (Function.prototype.bind.apply(Extended, [null].concat(args)));"
        "            } else {"
        "                thiz.__proto__ = new Extended();"
        "            }"
        "            return thiz.__proto__;"
        "        };"
        ""
        "        __extends_ns(Child, Parent);"
        "        Child.__isPrototypeImplementationObject = true;"
        "        Child.__proto__ = Parent;"
        "        Child.prototype.__parent = Parent;"
        "        Child.prototype.__child = Child;"
        ""
        "        if (__originalExtends) {"
        "            __originalExtends(Child, Parent);"
        "        }"
        "    };"
        ""
        "    var __extends_ts = function (child, parent) {"
        "        extendStaticFunctions(child, parent);"
        "        assignPrototypeFromParentToChild(parent, child);"
        "    };"
        ""
        "    var __extends_ns = function (child, parent) {"
        "        if (!parent.extend) {"
        "            assignPropertiesFromParentToChild(parent, child);"
        "        }"
        ""
        "        assignPrototypeFromParentToChild(parent, child);"
        "    };"
        ""
        "    var extendStaticFunctions ="
        "        Object.setPrototypeOf"
        "        || (hasInternalProtoProperty() && function (child, parent) { child.__proto__ = parent; })"
        "        || assignPropertiesFromParentToChild;"
        ""
        "    function hasInternalProtoProperty() {"
        "        return { __proto__: [] } instanceof Array;"
        "    }"
        ""
        "    function assignPropertiesFromParentToChild(parent, child) {"
        "        for (var property in parent) {"
        "            if (parent.hasOwnProperty(property)) {"
        "                child[property] = parent[property];"
        "            }"
        "        }"
        "    }"
        ""
        "    function assignPrototypeFromParentToChild(parent, child) {"
        "        function __() {"
        "            this.constructor = child;"
        "        }"
        ""
        "        if (parent === null) {"
        "            child.prototype = Object.create(null);"
        "        } else {"
        "            __.prototype = parent.prototype;"
        "            child.prototype = new __();"
        "        }"
        "    }"
        ""
        "    Object.defineProperty(global, \"__extends\", { value: __extends });"
        "})()";

    Local<Context> context = isolate->GetCurrentContext();
    Local<Script> script;
    TryCatch tc(isolate);
    if (!Script::Compile(context, tns::ToV8String(isolate, source.c_str())).ToLocal(&script) && tc.HasCaught()) {
        tns::LogError(isolate, tc);
        assert(false);
    }
    assert(!script.IsEmpty());

    Local<Value> result;
    if (!script->Run(context).ToLocal(&result) && tc.HasCaught()) {
        tns::LogError(isolate, tc);
        assert(false);
    }
}

}
