#!/usr/bin/env python3
"""
AOT Direct Call Generator for NativeScript iOS Runtime.

Reads aot-config.json and generates AOTDirectCalls.h/.mm with per-method stubs
that use direct Objective-C calls, bypassing libffi entirely.

Usage:
    python3 scripts/generate-aot.py [config.json] [output_dir]

Defaults:
    config  = aot-config.json (project root)
    output  = NativeScript/runtime/
"""

import json
import os
import sys

# ---------------------------------------------------------------------------
# Type system
# ---------------------------------------------------------------------------

TYPES = {
    "void": {
        "c_type": "void",
    },
    "BOOL": {
        "c_type": "BOOL",
        "to_native": "tns::ToBool({arg})",
        "to_v8": "v8::Boolean::New(isolate, {result})",
        "native_to_v8": "v8::Boolean::New(isolate, {result})",
        "set_retval": "*(ffi_arg*){dest} = (bool){value}",
    },
    "id": {
        "c_type": "id",
        "to_native": "Interop::ToObject(context, {arg})",
        "needs_context": True,
        "is_id": True,
        "native_to_v8": None,
    },
    "SEL": {
        "c_type": "SEL",
        "to_native": "sel_registerName(tns::ToString(isolate, {arg}).c_str())",
    },
    "Class": {
        "c_type": "Class",
        "to_native_special": True,
    },
    "int": {
        "c_type": "int",
        "to_native": "(int)tns::ToNumber(isolate, {arg})",
        "to_v8": "Number::New(isolate, (double){result})",
        "native_to_v8": "Number::New(isolate, (double){result})",
        "set_retval": "*static_cast<int*>({dest}) = (int){value}",
    },
    "uint": {
        "c_type": "unsigned int",
        "to_native": "(unsigned int)tns::ToNumber(isolate, {arg})",
        "to_v8": "Number::New(isolate, (double){result})",
        "native_to_v8": "Number::New(isolate, (double){result})",
        "set_retval": "*static_cast<unsigned int*>({dest}) = (unsigned int){value}",
    },
    "long": {
        "c_type": "long",
        "to_native": "(long)tns::ToNumber(isolate, {arg})",
        "to_v8": "Number::New(isolate, (double){result})",
        "native_to_v8": "Number::New(isolate, (double){result})",
        "set_retval": "*static_cast<long*>({dest}) = (long){value}",
    },
    "ulong": {
        "c_type": "unsigned long",
        "to_native": "(unsigned long)tns::ToNumber(isolate, {arg})",
        "to_v8": "Number::New(isolate, (double){result})",
        "native_to_v8": "Number::New(isolate, (double){result})",
        "set_retval": "*static_cast<unsigned long*>({dest}) = (unsigned long){value}",
    },
    "longlong": {
        "c_type": "long long",
        "to_native": "(long long)tns::ToNumber(isolate, {arg})",
        "to_v8": "Number::New(isolate, (double){result})",
        "native_to_v8": "Number::New(isolate, (double){result})",
        "set_retval": "*static_cast<long long*>({dest}) = (long long){value}",
    },
    "ulonglong": {
        "c_type": "unsigned long long",
        "to_native": "(unsigned long long)tns::ToNumber(isolate, {arg})",
        "to_v8": "Number::New(isolate, (double){result})",
        "native_to_v8": "Number::New(isolate, (double){result})",
        "set_retval": "*static_cast<unsigned long long*>({dest}) = (unsigned long long){value}",
    },
    "float": {
        "c_type": "float",
        "to_native": "(float)tns::ToNumber(isolate, {arg})",
        "to_v8": "Number::New(isolate, (double){result})",
        "native_to_v8": "Number::New(isolate, (double){result})",
        "set_retval": "*static_cast<float*>({dest}) = (float){value}",
    },
    "double": {
        "c_type": "double",
        "to_native": "(double)tns::ToNumber(isolate, {arg})",
        "to_v8": "Number::New(isolate, (double){result})",
        "native_to_v8": "Number::New(isolate, (double){result})",
        "set_retval": "*static_cast<double*>({dest}) = (double){value}",
    },
    "char": {
        "c_type": "char",
        "to_native": "(char)tns::ToNumber(isolate, {arg})",
        "to_v8": "Number::New(isolate, (double){result})",
        "native_to_v8": "Number::New(isolate, (double){result})",
        "set_retval": "*static_cast<char*>({dest}) = (char){value}",
    },
    "uchar": {
        "c_type": "unsigned char",
        "to_native": "(unsigned char)tns::ToNumber(isolate, {arg})",
        "to_v8": "Number::New(isolate, (double){result})",
        "native_to_v8": "Number::New(isolate, (double){result})",
        "set_retval": "*static_cast<unsigned char*>({dest}) = (unsigned char){value}",
    },
    "short": {
        "c_type": "short",
        "to_native": "(short)tns::ToNumber(isolate, {arg})",
        "to_v8": "Number::New(isolate, (double){result})",
        "native_to_v8": "Number::New(isolate, (double){result})",
        "set_retval": "*static_cast<short*>({dest}) = (short){value}",
    },
    "ushort": {
        "c_type": "unsigned short",
        "to_native": "(unsigned short)tns::ToNumber(isolate, {arg})",
        "to_v8": "Number::New(isolate, (double){result})",
        "native_to_v8": "Number::New(isolate, (double){result})",
        "set_retval": "*static_cast<unsigned short*>({dest}) = (unsigned short){value}",
    },
}


def is_id(t):
    return TYPES[t].get("is_id", False)


def needs_context(ret, args):
    if is_id(ret):
        return True
    return any(TYPES[a].get("needs_context") or is_id(a) for a in args)


def sanitize_selector(sel):
    return sel.rstrip(":").replace(":", "_")


def method_stub_name(cls, sel):
    return f"AOT_{cls}_{sanitize_selector(sel)}"


def build_objc_call(cls, sel, args, target="target"):
    if not args:
        return f"[({cls}*){target} {sel}]"
    parts = [p for p in sel.split(":") if p]
    expr = " ".join(f"{p}:arg{i}" for i, p in enumerate(parts))
    return f"[({cls}*){target} {expr}]"


def build_super_call(cls, sel, ret, args):
    c_ret = TYPES[ret]["c_type"]
    c_args = ["objc_super*", "SEL"] + [TYPES[a]["c_type"] for a in args]
    cast = f"(({c_ret}(*)({', '.join(c_args)}))"
    arg_str = ", ".join(f"arg{i}" for i in range(len(args)))
    suffix = f", {arg_str}" if arg_str else ""
    return f"{cast}objc_msgSendSuper)(&sup, @selector({sel}){suffix})"


def block_invoke_name(ret, args):
    parts = [ret]
    if not args:
        parts.append("noargs")
    else:
        parts.extend(args)
    return "AOTBlockInvoke_" + "_".join(parts)


# ---------------------------------------------------------------------------
# Per-method stub generator
# ---------------------------------------------------------------------------

def gen_method_stub(method):
    cls = method["class"]
    sel = method["selector"]
    ret = method["ret"]
    args = method["args"]
    name = method_stub_name(cls, sel)
    ret_info = TYPES[ret]
    is_void = ret == "void"
    ret_is_id = is_id(ret)
    want_context = needs_context(ret, args)

    lines = []
    lines.append(f"// {cls} -[{sel}]")
    lines.append(f"static void {name}(const FunctionCallbackInfo<Value>& info) {{")
    lines.append("    try {")
    lines.append("        Isolate* isolate = info.GetIsolate();")
    if want_context:
        lines.append("        Local<Context> context = isolate->GetCurrentContext();")
    lines.append("        bool callSuper;")
    lines.append("        id target = AOTExtractTarget(isolate, info.This(), callSuper);")
    lines.append("        if (target == nil) return;")

    # Convert arguments
    for i, arg in enumerate(args):
        arg_info = TYPES[arg]
        if arg == "Class":
            lines.append(f"        Class arg{i} = nil;")
            lines.append(f"        BaseDataWrapper* argW{i} = tns::GetValue(isolate, info[{i}]);")
            lines.append(f"        if (argW{i} != nullptr && argW{i}->Type() == WrapperType::ObjCClass)")
            lines.append(f"            arg{i} = static_cast<ObjCClassWrapper*>(argW{i})->Klass();")
            lines.append(f"        else if (tns::IsString(info[{i}]))")
            lines.append(f"            arg{i} = objc_getClass(tns::ToString(isolate, info[{i}]).c_str());")
        else:
            conv = arg_info["to_native"].format(arg=f"info[{i}]")
            lines.append(f"        {arg_info['c_type']} arg{i} = {conv};")

    # The call
    objc_call = build_objc_call(cls, sel, args)
    super_call = build_super_call(cls, sel, ret, args)

    lines.append("")
    if not is_void:
        lines.append(f"        {ret_info['c_type']} result;")
    lines.append("        @try {")
    lines.append("            if (callSuper) {")
    lines.append(f"                objc_super sup = {{target, [{cls} class]}};")
    if is_void:
        lines.append(f"                {super_call};")
    else:
        lines.append(f"                result = {super_call};")
    lines.append("            } else {")
    if is_void:
        lines.append(f"                {objc_call};")
    else:
        lines.append(f"                result = {objc_call};")
    lines.append("            }")
    lines.append("        } @catch (NSException* e) {")
    lines.append("            throw NativeScriptException([[e description] UTF8String]);")
    lines.append("        }")

    # Return value
    if not is_void:
        lines.append("")
        if ret_is_id:
            lines.append("        info.GetReturnValue().Set(AOTWrapId(context, result));")
        else:
            to_v8 = ret_info["to_v8"].format(result="result")
            lines.append(f"        info.GetReturnValue().Set({to_v8});")

    lines.append("    } catch (NativeScriptException& ex) {")
    lines.append("        ex.ReThrowToV8(info.GetIsolate());")
    lines.append("    }")
    lines.append("}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Block invoke stub generator (per-signature, unchanged approach)
# ---------------------------------------------------------------------------

def gen_block_invoke(ret, args):
    name = block_invoke_name(ret, args)
    ret_info = TYPES[ret]
    is_void = ret == "void"
    ret_is_id = is_id(ret)

    c_params = ["void* _block"]
    for i, arg in enumerate(args):
        c_params.append(f"{TYPES[arg]['c_type']} nativeArg{i}")
    c_params_str = ", ".join(c_params)

    lines = []
    lines.append(f"static {ret_info['c_type']} {name}({c_params_str}) {{")
    lines.append("    Interop::JSBlock* block = static_cast<Interop::JSBlock*>(_block);")
    lines.append("    MethodCallbackWrapper* wrapper = static_cast<MethodCallbackWrapper*>(block->userData);")
    lines.append("    Isolate* isolate = wrapper->isolateWrapper_.Isolate();")
    lines.append("")
    lines.append("    if (!wrapper->isolateWrapper_.IsValid()) {")
    if is_void:
        lines.append("        return;")
    elif ret_is_id:
        lines.append("        return nil;")
    else:
        lines.append(f"        return ({ret_info['c_type']})0;")
    lines.append("    }")
    lines.append("")
    lines.append("    v8::Locker locker(isolate);")
    lines.append("    Isolate::Scope isolateScope(isolate);")
    lines.append("    HandleScope handleScope(isolate);")
    lines.append("    auto cache = Caches::Get(isolate);")
    lines.append("    Local<Context> context = cache->GetContext();")
    lines.append("    Context::Scope contextScope(context);")
    lines.append("")

    if args:
        lines.append(f"    Local<Value> jsArgs[{len(args)}];")
        for i, arg in enumerate(args):
            if is_id(arg):
                lines.append(f"    if (nativeArg{i} == nil) {{")
                lines.append(f"        jsArgs[{i}] = Null(isolate);")
                lines.append(f"    }} else {{")
                lines.append(f"        ObjCDataWrapper* w{i} = new ObjCDataWrapper(nativeArg{i});")
                lines.append(f"        jsArgs[{i}] = ArgConverter::ConvertArgument(context, w{i});")
                lines.append(f"        tns::DeleteWrapperIfUnused(isolate, jsArgs[{i}], w{i});")
                lines.append(f"    }}")
            elif arg == "BOOL":
                lines.append(f"    jsArgs[{i}] = v8::Boolean::New(isolate, nativeArg{i});")
            else:
                n2v = TYPES[arg].get("native_to_v8")
                if n2v:
                    lines.append(f"    jsArgs[{i}] = {n2v.format(result=f'nativeArg{i}')};")
                else:
                    lines.append(f"    jsArgs[{i}] = Number::New(isolate, (double)nativeArg{i});")
        lines.append("")

    lines.append("    Local<v8::Function> callback = wrapper->callback_->Get(isolate).As<v8::Function>();")
    lines.append("    Local<Value> result;")
    if args:
        lines.append(f"    bool success = callback->Call(context, context->Global(), {len(args)}, jsArgs).ToLocal(&result);")
    else:
        lines.append("    bool success = callback->Call(context, context->Global(), 0, nullptr).ToLocal(&result);")

    if is_void:
        lines.append("    (void)success;")
    else:
        lines.append("")
        lines.append("    if (!success || result.IsEmpty() || result->IsNullOrUndefined()) {")
        if ret_is_id:
            lines.append("        return nil;")
        else:
            lines.append(f"        return ({ret_info['c_type']})0;")
        lines.append("    }")
        if ret_is_id:
            lines.append("    return Interop::ToObject(context, result);")
        elif ret == "BOOL":
            lines.append("    return tns::ToBool(result);")
        else:
            lines.append(f"    return ({ret_info['c_type']})tns::ToNumber(isolate, result);")

    lines.append("}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Matcher generators
# ---------------------------------------------------------------------------

def gen_method_matcher(methods):
    by_class = {}
    for m in methods:
        if m.get("static"):
            continue
        by_class.setdefault(m["class"], []).append(m)

    lines = []
    lines.append("v8::FunctionCallback GetAOTDirectCall(const char* className, const char* selectorName) {")

    for cls in sorted(by_class.keys()):
        entries = by_class[cls]
        lines.append(f'    if (strcmp(className, "{cls}") == 0) {{')
        for m in entries:
            sel = m["selector"]
            name = method_stub_name(cls, sel)
            lines.append(f'        if (strcmp(selectorName, "{sel}") == 0) return {name};')
        lines.append("    }")
    lines.append("    return nullptr;")
    lines.append("}")
    return "\n".join(lines)


ENCODING_MAP = {
    "void": ["VoidEncoding"],
    "BOOL": ["BoolEncoding"],
    "id": ["IdEncoding", "InstanceTypeEncoding", "InterfaceDeclarationReference"],
    "SEL": ["SelectorEncoding"],
    "Class": ["ClassEncoding"],
    "int": ["IntEncoding"],
    "uint": ["UIntEncoding"],
    "long": ["LongEncoding"],
    "ulong": ["ULongEncoding"],
    "longlong": ["LongLongEncoding"],
    "ulonglong": ["ULongLongEncoding"],
    "float": ["FloatEncoding"],
    "double": ["DoubleEncoding"],
    "char": ["CharEncoding"],
    "uchar": ["UCharEncoding"],
    "short": ["ShortEncoding"],
    "ushort": ["UShortEncoding"],
}


def gen_block_matcher(block_patterns):
    by_count = {}
    for p in block_patterns:
        n = len(p["args"])
        by_count.setdefault(n, []).append(p)

    lines = []
    lines.append("typedef void* AOTBlockInvokeFunc;")
    lines.append("")
    lines.append("AOTBlockInvokeFunc GetAOTBlockInvoke(const TypeEncoding* typeEncoding, int argsCount) {")
    lines.append("    BinaryTypeEncodingType retType = typeEncoding->type;")
    lines.append("")

    for count in sorted(by_count.keys()):
        patterns = by_count[count]
        lines.append(f"    if (argsCount == {count}) {{")

        if count > 0:
            lines.append("        const TypeEncoding* pEnc = typeEncoding;")
            for i in range(count):
                lines.append(f"        pEnc = pEnc->next();")
                lines.append(f"        BinaryTypeEncodingType p{i}Type = pEnc->type;")

        for p in patterns:
            ret = p["ret"]
            args = p["args"]
            bname = block_invoke_name(ret, args)

            conditions = []
            ret_encs = ENCODING_MAP[ret]
            ret_checks = [f"retType == BinaryTypeEncodingType::{e}" for e in ret_encs]
            conditions.append(f"({' || '.join(ret_checks)})" if len(ret_checks) > 1 else ret_checks[0])

            for i, arg in enumerate(args):
                arg_encs = ENCODING_MAP[arg]
                arg_checks = [f"p{i}Type == BinaryTypeEncodingType::{e}" for e in arg_encs]
                conditions.append(f"({' || '.join(arg_checks)})" if len(arg_checks) > 1 else arg_checks[0])

            cond_str = " && ".join(conditions)
            lines.append(f"        if ({cond_str})")
            lines.append(f"            return (AOTBlockInvokeFunc){bname};")

        lines.append("        return nullptr;")
        lines.append("    }")
        lines.append("")

    lines.append("    return nullptr;")
    lines.append("}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# File generators
# ---------------------------------------------------------------------------

HEADER = """\
// AUTO-GENERATED by scripts/generate-aot.py — do not edit manually.
#ifndef AOTDirectCalls_h
#define AOTDirectCalls_h

#include "Common.h"
#include "Metadata.h"

namespace tns {

v8::FunctionCallback GetAOTDirectCall(const char* className, const char* selectorName);

typedef void* AOTBlockInvokeFunc;
AOTBlockInvokeFunc GetAOTBlockInvoke(const TypeEncoding* typeEncoding, int argsCount);

}

#endif /* AOTDirectCalls_h */
"""

PREAMBLE = """\
// AUTO-GENERATED by scripts/generate-aot.py — do not edit manually.
#include <Foundation/Foundation.h>
#include <objc/message.h>
#include "AOTDirectCalls.h"
#include "ArgConverter.h"
#include "Caches.h"
#include "Helpers.h"
#include "Interop.h"
#include "NativeScriptException.h"

using namespace v8;

namespace tns {

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static inline id AOTExtractTarget(Isolate* isolate, Local<Object> receiver,
                                  bool& callSuper) {
    BaseDataWrapper* wrapper = tns::GetValue(isolate, receiver);
    if (wrapper == nullptr) { callSuper = false; return nil; }

    id target = nil;
    callSuper = false;

    if (wrapper->Type() == WrapperType::ObjCAllocObject) {
        ObjCAllocDataWrapper* allocWrapper =
            static_cast<ObjCAllocDataWrapper*>(wrapper);
        target = [allocWrapper->Klass() alloc];
    } else if (wrapper->Type() == WrapperType::ObjCObject) {
        ObjCDataWrapper* objcWrapper =
            static_cast<ObjCDataWrapper*>(wrapper);
        target = objcWrapper->Data();
        std::string className = object_getClassName(target);
        auto cache = Caches::Get(isolate);
        callSuper = cache->ClassPrototypes.find(className) != cache->ClassPrototypes.end();
    }

    return target;
}

static inline Local<Value> AOTWrapId(Local<Context> context, id result) {
    Isolate* isolate = context->GetIsolate();
    if (result == nil) return Null(isolate);

    if ([result isKindOfClass:[NSString class]]) {
        return tns::ToV8String(isolate, [(NSString*)result UTF8String]);
    }
    if ([result isKindOfClass:[NSNull class]]) {
        return Null(isolate);
    }
    if ([result isKindOfClass:[NSNumber class]] && ![result isKindOfClass:[NSDecimalNumber class]]) {
        return Number::New(isolate, [(NSNumber*)result doubleValue]);
    }

    auto* wrapper = new ObjCDataWrapper(result);
    Local<Value> jsResult = ArgConverter::ConvertArgument(context, wrapper);
    tns::DeleteWrapperIfUnused(isolate, jsResult, wrapper);
    return jsResult;
}

"""


def generate(config_path, output_dir):
    with open(config_path) as f:
        config = json.load(f)

    methods = config.get("methods", [])
    block_patterns = config.get("blockPatterns", [])

    # --- Header ---
    header_path = os.path.join(output_dir, "AOTDirectCalls.h")
    with open(header_path, "w") as f:
        f.write(HEADER)
    print(f"  wrote {header_path}")

    # --- Implementation ---
    impl_path = os.path.join(output_dir, "AOTDirectCalls.mm")
    parts = [PREAMBLE]

    instance_methods = [m for m in methods if not m.get("static")]
    parts.append("// ---------------------------------------------------------------------------")
    parts.append(f"// Per-method stubs ({len(instance_methods)} methods)")
    parts.append("// ---------------------------------------------------------------------------\n")
    for m in instance_methods:
        parts.append(gen_method_stub(m))
        parts.append("")

    parts.append("// ---------------------------------------------------------------------------")
    parts.append(f"// Block invoke stubs ({len(block_patterns)} patterns)")
    parts.append("// ---------------------------------------------------------------------------\n")
    for p in block_patterns:
        parts.append(gen_block_invoke(p["ret"], p["args"]))
        parts.append("")

    parts.append("// ---------------------------------------------------------------------------")
    parts.append("// Matchers")
    parts.append("// ---------------------------------------------------------------------------\n")
    parts.append(gen_method_matcher(methods))
    parts.append("")
    parts.append(gen_block_matcher(block_patterns))
    parts.append("")

    parts.append("}  // namespace tns")
    parts.append("")

    with open(impl_path, "w") as f:
        f.write("\n".join(parts))
    print(f"  wrote {impl_path}")

    print(f"\n  {len(instance_methods)} method stubs, {len(block_patterns)} block invoke stubs generated.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)

    config_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(project_root, "aot-config.json")
    output_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(project_root, "NativeScript", "runtime")

    print(f"Generating AOT stubs from {config_path}...")
    generate(config_path, output_dir)
    print("Done.")
