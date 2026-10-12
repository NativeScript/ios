#!/usr/bin/env python3
"""Generate NativeScript AOT call stubs.

Reads an AOT config listing (class, selector) pairs and the metadata
generator's JSON output (one <Module>.json per module, from -output-json),
and writes one Objective-C file of stubs that send each message through a
cast objc_msgSend with the exact C ABI types from metadata. The stubs talk to
the runtime only through <NativeScript/NativeScriptAOT.h>; the file needs no
framework header because struct layouts are emitted from metadata.

Config schema:
    {"methods": [{"class": "UIScreen", "selector": "scale"},
                 {"class": "UIColor", "selector": "colorWithRed:green:blue:alpha:",
                  "static": true}]}
Unknown keys are ignored.

Usage:
    generate-aot.py CONFIG --metadata DIR [--output FILE] [--report]
"""

import argparse
import json
import os
import re
import sys


class InputError(Exception):
    pass


class Unsupported(Exception):
    def __init__(self, message, category):
        super().__init__(message)
        self.category = category


RECORD = "struct not representable"


# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------


class Metadata:
    def __init__(self, directory):
        if not os.path.isdir(directory):
            raise InputError(f"metadata directory not found: {directory}")
        self.classes = {}
        self.protocols = {}
        self.records = {}  # (kind, module, name) -> item
        self.records_by_name = {}  # (kind, name) -> item
        self.enums = {}
        files = sorted(f for f in os.listdir(directory) if f.endswith(".json"))
        if not files:
            raise InputError(f"no .json files in {directory}")
        for name in files:
            path = os.path.join(directory, name)
            try:
                with open(path) as f:
                    data = json.load(f)
                items = data["Items"]
            except (ValueError, KeyError, TypeError) as e:
                raise InputError(f"malformed metadata file {path}: {e}")
            for item in items:
                self._index(item)

    def _index(self, item):
        kind = item.get("Type")
        if kind in ("Interface", "Protocol"):
            table = self.classes if kind == "Interface" else self.protocols
            for key in ("Name", "JsName", "DemangledName"):
                value = item.get(key)
                if value:
                    table.setdefault((key, value), item)
        elif kind in ("Struct", "Union"):
            self.records.setdefault((kind, item.get("Module"), item["Name"]), item)
            self.records_by_name.setdefault((kind, item["Name"]), item)
        elif kind == "Enum":
            self.enums.setdefault(item.get("JsName") or item["Name"], item)

    @staticmethod
    def _lookup(table, name):
        for key in ("Name", "JsName", "DemangledName"):
            item = table.get((key, name))
            if item is not None:
                return item
        return None

    def find_class(self, name):
        return self._lookup(self.classes, name)

    def find_protocol(self, name):
        return self._lookup(self.protocols, name)

    def find_record(self, kind, module, name):
        item = self.records.get((kind, module, name))
        if item is None:
            item = self.records_by_name.get((kind, name))
        return item

    def find_method(self, class_name, selector, is_static):
        """Returns (method, binding class name) or None.

        Searches the declaration's own methods and property accessors, then
        its protocols, then its Base chain. The binding class is the one whose
        template the runtime binds the member on: the declaring class, or for
        a protocol member the class in the chain that adopts the protocol. A
        protocol name is accepted as the starting point and binds itself.
        """
        pending = []
        cls = self.find_class(class_name)
        if cls is not None:
            pending.append((cls, cls["Name"]))
        proto = self.find_protocol(class_name)
        if proto is not None:
            pending.append((proto, cls["Name"] if cls is not None else proto["Name"]))
        methods_key = "StaticMethods" if is_static else "InstanceMethods"
        props_key = "StaticProperties" if is_static else "InstanceProperties"
        seen = set()
        while pending:
            decl, binder = pending.pop(0)
            ident = (decl.get("Type"), decl.get("Name"))
            if ident in seen:
                continue
            seen.add(ident)
            for method in decl.get(methods_key) or []:
                if method.get("Name") == selector:
                    return method, binder
            for prop in decl.get(props_key) or []:
                for accessor in ("Getter", "Setter"):
                    method = prop.get(accessor)
                    if method and method.get("Name") == selector:
                        return method, binder
            protocols = [self.find_protocol(p) for p in decl.get("Protocols") or []]
            pending[0:0] = [(p, binder) for p in protocols if p is not None]
            base = self.find_class(decl["Base"]) if decl.get("Base") else None
            if base is not None:
                pending.append((base, base["Name"]))
        return None


# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

# metadata kind -> (C type, signed?)
INTEGERS = {
    "Char": ("signed char", True),
    "UChar": ("unsigned char", False),
    "Short": ("short", True),
    "Ushort": ("unsigned short", False),
    "UShort": ("unsigned short", False),
    "Int": ("int", True),
    "UInt": ("unsigned int", False),
    "Long": ("long", True),
    "ULong": ("unsigned long", False),
    "LongLong": ("long long", True),
    "ULongLong": ("unsigned long long", False),
}

OBJECT_KINDS = ("Id", "Instancetype", "Interface", "BridgedInterface")


class CType:
    """A resolved parameter or return type.

    kind is one of void, bool, int, uint, float, double, sel, class, object,
    pointer, struct.
    """

    def __init__(self, kind, ctype, record=None):
        self.kind = kind
        self.ctype = ctype
        self.record = record


def describe(t):
    if not isinstance(t, dict):
        return repr(t)
    kind = t.get("Type")
    name = t.get("Name")
    return f"{kind} {name}" if name else str(kind)


class TypeMapper:
    def __init__(self, metadata):
        self.md = metadata
        self.records = {}  # id(item) -> RecordDef
        self.record_order = []
        self.vectors = {}  # (ctype, size) -> typedef name
        self.typedef_names = set()

    def unwrap(self, t):
        while isinstance(t, dict):
            kind = t.get("Type")
            if kind in ("Nullable", "NonNullable"):
                t = t.get("InnerType")
            elif kind == "TypeArgument":
                t = t.get("UnderlyingType")
            elif kind == "Enum":
                underlying = t.get("UnderlyingType")
                if underlying is None:
                    item = self.md.enums.get(t.get("Name"))
                    underlying = item.get("UnderlyingType") if item else None
                if underlying is None:
                    raise Unsupported(f"enum {t.get('Name')} has no underlying type in metadata",
                                      "enum without underlying type in metadata")
                t = underlying
            else:
                return t
        raise InputError(f"malformed type {t!r}")

    def resolve(self, t, is_return):
        t = self.unwrap(t)
        kind = t.get("Type")
        if kind == "Void":
            if not is_return:
                raise Unsupported("void parameter", "void parameter")
            return CType("void", "void")
        if kind == "Bool":
            return CType("bool", "BOOL")
        if kind in ("LongLong", "ULongLong"):
            # The generic path converts these to and from BigInt beyond 2^53,
            # which the bridge's 64-bit getters and setters do not model.
            raise Unsupported(f"{kind} (BigInt marshalling)", "long long (BigInt marshalling)")
        if kind in INTEGERS:
            ctype, signed = INTEGERS[kind]
            return CType("int" if signed else "uint", ctype)
        if kind == "Float":
            return CType("float", "float")
        if kind == "Double":
            return CType("double", "double")
        if kind == "Selector":
            return CType("sel", "SEL")
        if kind == "Class":
            return CType("class", "Class")
        if kind in OBJECT_KINDS:
            if kind == "BridgedInterface" and t.get("BridgedTo") == "[None]":
                raise Unsupported(f"unbridged CF type {t.get('Name')}", "unbridged CF type")
            return CType("object", "id")
        if kind == "Pointer":
            inner = self.unwrap(t.get("PointerType"))
            if inner.get("Type") != "Void":
                raise Unsupported(f"typed pointer to {describe(inner)} (runtime needs the pointee type)",
                                  "typed pointer")
            return CType("pointer", "void*")
        if kind == "Struct":
            record = self.record(t, "Struct")
            return CType("struct", record.cname, record)
        if kind == "Block":
            what = "block " + ("return" if is_return else "parameter")
            raise Unsupported(what, what)
        if kind == "FunctionPointer":
            what = "function pointer " + ("return" if is_return else "parameter")
            raise Unsupported(what, what)
        raise Unsupported(f"type {describe(t)}", f"type {kind}")

    # --- records ---

    def record(self, t, kind):
        item = self.md.find_record(kind, t.get("Module"), t.get("Name"))
        if item is None:
            raise Unsupported(f"{kind.lower()} {t.get('Name')} not found in metadata", RECORD)
        key = id(item)
        existing = self.records.get(key)
        if existing is not None:
            if existing.error:
                raise existing.error
            if existing.building:
                raise Unsupported(f"{kind.lower()} {item['Name']} contains itself by value", RECORD)
            return existing
        rec = RecordDef(item, kind, self._unique_name("AOT_" + sanitize(item["Name"])))
        self.records[key] = rec
        rec.building = True
        try:
            fields = item.get("Fields") or []
            if not fields:
                raise Unsupported(f"{kind.lower()} {item['Name']} has no fields in metadata", RECORD)
            rec.fields = self._fields(fields)
        except Unsupported as e:
            rec.error = Unsupported(f"{kind.lower()} {item['Name']}: {e}", e.category)
            raise rec.error
        finally:
            rec.building = False
        self.record_order.append(rec)
        return rec

    def _unique_name(self, base):
        name = base
        n = 2
        while name in self.typedef_names:
            name = f"{base}_{n}"
            n += 1
        self.typedef_names.add(name)
        return name

    def _fields(self, fields):
        out = []
        for i, field in enumerate(fields):
            name = field.get("Name") or ""
            if not IDENT.match(name) or name in C_KEYWORDS:
                name = f"f{i}"
            # Without BitWidth in metadata a bit-field struct (NSDecimal) gets
            # the same wrong layout as the runtime's own description of it.
            width = field.get("BitWidth")
            if width is None:
                out.append(self.field_decl(field.get("Signature"), name))
            elif int(width) == 0:
                out.append(self.field_decl(field.get("Signature"), "") + " : 0")
            else:
                out.append(self.field_decl(field.get("Signature"), name) + f" : {int(width)}")
        return out

    def field_decl(self, t, name):
        """Returns a C declaration for a field of type t named name."""
        t = self.unwrap(t)
        kind = t.get("Type")
        if kind == "Bool":
            return f"BOOL {name}"
        if kind in INTEGERS:
            return f"{INTEGERS[kind][0]} {name}"
        if kind == "Unichar":
            return f"unsigned short {name}"
        if kind in ("Float", "Double"):
            return f"{kind.lower()} {name}"
        if kind in ("Pointer", "CString", "FunctionPointer", "Block", "Selector",
                    "Class", "Protocol") or kind in OBJECT_KINDS:
            return f"void* {name}"
        if kind in ("Struct", "Union"):
            return f"{self.record(t, kind).cname} {name}"
        if kind in ("AnonymousStruct", "AnonymousUnion"):
            keyword = "struct" if kind == "AnonymousStruct" else "union"
            if not t.get("Fields"):
                raise Unsupported(f"field {name} is an empty {keyword}", RECORD)
            inner = "; ".join(self._fields(t["Fields"])) + ";"
            return f"{keyword} {{ {inner} }} {name}"
        if kind == "ConstantArray":
            return self.field_decl(t.get("ArrayType"), f"{name}[{int(t.get('Size'))}]")
        if kind == "ExtVector":
            return f"{self.vector(t)} {name}"
        raise Unsupported(f"field {name} of type {describe(t)}", RECORD)

    def vector(self, t):
        inner = self.unwrap(t.get("InnerType"))
        kind = inner.get("Type")
        if kind in INTEGERS:
            ctype = INTEGERS[kind][0]
        elif kind in ("Float", "Double"):
            ctype = kind.lower()
        else:
            raise Unsupported(f"vector of {describe(inner)}", RECORD)
        size = int(t.get("Size"))
        key = (ctype, size)
        if key not in self.vectors:
            self.vectors[key] = self._unique_name(f"AOT_{ctype.replace(' ', '_')}{size}")
        return self.vectors[key]

    def emit_typedefs(self):
        lines = []
        for (ctype, size), name in sorted(self.vectors.items(), key=lambda kv: kv[1]):
            lines.append(f"typedef {ctype} {name} __attribute__((ext_vector_type({size})));")
        for rec in self.record_order:
            keyword = "struct" if rec.kind == "Struct" else "union"
            lines.append(f"typedef {keyword} {{")
            for decl in rec.fields:
                lines.append(f"  {decl};")
            lines.append(f"}} {rec.cname};")
        return lines


class RecordDef:
    def __init__(self, item, kind, cname):
        self.item = item
        self.kind = kind
        self.cname = cname
        self.fields = []
        self.error = None
        self.building = False

    @property
    def runtime_name(self):
        return self.item.get("JsName") or self.item["Name"]


IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
C_KEYWORDS = {
    "auto", "break", "case", "char", "const", "continue", "default", "do",
    "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
    "int", "long", "register", "restrict", "return", "short", "signed",
    "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
    "void", "volatile", "while", "id", "SEL", "Class", "BOOL", "YES", "NO",
    "nil", "self", "super", "in", "out", "inout", "bycopy", "byref", "oneway",
}


# ---------------------------------------------------------------------------
# Code generation
# ---------------------------------------------------------------------------


def sanitize(name):
    return re.sub(r"[^A-Za-z0-9_]", "_", name)


def sanitize_selector(sel):
    return sanitize(sel.rstrip(":").replace(":", "_"))


def method_stub_name(cls, sel, is_static):
    suffix = "_static" if is_static else ""
    return f"AOT_{sanitize(cls)}_{sanitize_selector(sel)}{suffix}"


def _build_msgsend_call(fn, receiver, ret, args):
    params = ", ".join(["id", "SEL"] + [a.ctype for a in args])
    values = "".join(f", a{i}" for i in range(len(args)))
    return f"(({ret.ctype} (*)({params})){fn})({receiver}, sel{values})"


def build_super_call(fn, ret, args):
    params = ", ".join(["struct objc_super*", "SEL"] + [a.ctype for a in args])
    values = "".join(f", a{i}" for i in range(len(args)))
    return f"(({ret.ctype} (*)({params})){fn})(&sup, sel{values})"


ARG_GETTERS = {
    "object": ("id", "nil", "__ns_aot_arg_object"),
    "sel": ("SEL", "NULL", "__ns_aot_arg_selector"),
    "class": ("Class", "Nil", "__ns_aot_arg_class"),
    "pointer": ("void*", "NULL", "__ns_aot_arg_pointer"),
}

RETURN_SETTERS = {
    "bool": "__ns_aot_return_bool(info, r);",
    "int": "__ns_aot_return_int64(info, (int64_t)r);",
    "uint": "__ns_aot_return_uint64(info, (uint64_t)r);",
    "float": "__ns_aot_return_double(info, (double)r);",
    "double": "__ns_aot_return_double(info, r);",
    "sel": "__ns_aot_return_selector(info, r);",
    "class": "__ns_aot_return_class(info, r);",
    "pointer": "__ns_aot_return_pointer(info, r);",
}

RETURN_INIT = {
    "bool": "NO", "int": "0", "uint": "0", "float": "0", "double": "0",
    "sel": "NULL", "class": "Nil", "object": "nil", "pointer": "NULL",
}


class Stub:
    def __init__(self, cls, selector, is_static, method, ret, args, name):
        self.cls = cls
        self.selector = selector
        self.is_static = is_static
        self.method = method
        self.ret = ret
        self.args = args
        self.name = name
        self.registrations = []

    def flags(self):
        return set(self.method.get("Flags") or [])

    def emit(self):
        out = []
        w = out.append
        w(f"static bool {self.name}(NSAOTCallInfo info) {{")
        w(f"  if (__ns_aot_arg_count(info) != {len(self.args)}) return false;")

        struct_vars = {}
        for t in [self.ret] + self.args:
            if t.kind == "struct" and t.record.cname not in struct_vars:
                var = f"st{len(struct_vars)}"
                struct_vars[t.record.cname] = var
                w(f"  static NSAOTStructType {var} = NULL;")
                w(f"  if (!{var}) {var} = __ns_aot_struct_type(\"{t.record.runtime_name}\");")
                w(f"  if (!{var}) return false;")

        w(f"  SEL sel = @selector({self.selector});")
        if self.is_static:
            w("  Class cls = __ns_aot_get_static_class(info);")
            w("  if (cls == nil) return false;")
        else:
            w("  bool callSuper = false;")
            w("  id target = __ns_aot_get_target(info, sel, &sel, &callSuper);")
            w("  if (target == nil) return false;")

        for i, a in enumerate(self.args):
            k = a.kind
            if k == "bool":
                w(f"  BOOL a{i} = NO;")
                w(f"  if (!__ns_aot_arg_bool(info, {i}, &a{i})) return true;")
            elif k in ("int", "uint"):
                raw = "int64_t" if k == "int" else "uint64_t"
                getter = "__ns_aot_arg_int64" if k == "int" else "__ns_aot_arg_uint64"
                w(f"  {raw} raw{i} = 0;")
                w(f"  if (!{getter}(info, {i}, &raw{i})) return true;")
                w(f"  {a.ctype} a{i} = ({a.ctype})raw{i};")
            elif k in ("float", "double"):
                w(f"  double raw{i} = 0;")
                w(f"  if (!__ns_aot_arg_double(info, {i}, &raw{i})) return true;")
                w(f"  {a.ctype} a{i} = ({a.ctype})raw{i};")
            elif k == "struct":
                var = struct_vars[a.record.cname]
                w(f"  {a.ctype} a{i};")
                w(f"  if (!__ns_aot_arg_struct(info, {i}, {var}, &a{i})) return true;")
            else:
                ctype, init, getter = ARG_GETTERS[k]
                w(f"  {ctype} a{i} = {init};")
                w(f"  if (!{getter}(info, {i}, &a{i})) return true;")

        rk = self.ret.kind
        if rk == "struct":
            w(f"  {self.ret.ctype} r;")
        elif rk != "void":
            w(f"  {self.ret.ctype} r = {RETURN_INIT[rk]};")
        assign = "" if rk == "void" else "r = "
        if rk == "struct":
            send_fn = f"AOT_SEND_STRET({self.ret.ctype})"
            super_fn = f"AOT_SEND_SUPER_STRET({self.ret.ctype})"
        else:
            send_fn = "objc_msgSend"
            super_fn = "objc_msgSendSuper"

        w("  @try {")
        if self.is_static:
            w(f"    {assign}{_build_msgsend_call(send_fn, '(id)cls', self.ret, self.args)};")
        else:
            w("    if (callSuper) {")
            w("      struct objc_super sup = {target, class_getSuperclass(object_getClass(target))};")
            w(f"      {assign}{build_super_call(super_fn, self.ret, self.args)};")
            w("    } else {")
            w(f"      {assign}{_build_msgsend_call(send_fn, 'target', self.ret, self.args)};")
            w("    }")
        w("  } @catch (NSException* e) {")
        w("    __ns_aot_throw_exception(info, e);")
        w("    return true;")
        w("  }")

        if rk == "object":
            owned = "true" if "MethodOwnsReturnedCocoaObject" in self.flags() else "false"
            marshal = "false" if self.keeps_object_return() else "true"
            w(f"  __ns_aot_return_object(info, r, {owned}, {marshal});")
        elif rk == "struct":
            w(f"  __ns_aot_return_struct(info, {struct_vars[self.ret.record.cname]}, &r);")
        elif rk != "void":
            w(f"  {RETURN_SETTERS[rk]}")
        w("  return true;")
        w("}")
        return "\n".join(out)

    def keeps_object_return(self):
        """Mirrors the generic path, which leaves instancetype and
        NSMutableString returns as objects instead of JS primitives."""
        t = self.method["Signature"][0]
        while isinstance(t, dict) and t.get("Type") in ("Nullable", "NonNullable"):
            t = t.get("InnerType")
        if not isinstance(t, dict):
            return False
        if t.get("Type") == "Instancetype":
            return True
        return t.get("Type") == "Interface" and t.get("Name") == "NSMutableString"


SKIP_FLAGS = (
    ("MethodIsInitializer", "initializer"),
    ("MethodHasErrorOutParameter", "NSError** out-parameter"),
    ("MethodIsVariadic", "variadic"),
    ("MethodIsNullTerminatedVariadic", "variadic"),
)


# ARC rejects these in @selector(), and the stubs must compile under ARC.
ARC_FORBIDDEN_SELECTORS = {"retain", "release", "autorelease", "dealloc", "retainCount"}


def plan_entry(md, mapper, entry):
    """Returns (Stub, None, None) or (None, reason, category)."""
    cls, selector, is_static = entry
    found = md.find_method(cls, selector, is_static)
    if found is None:
        if md.find_class(cls) is None and md.find_protocol(cls) is None:
            return None, "class not found in metadata", "class not found"
        return None, "selector not found in metadata", "selector not found"
    method, binder = found
    if selector in ARC_FORBIDDEN_SELECTORS:
        return None, "memory-management selector", "memory-management selector"
    flags = set(method.get("Flags") or [])
    for flag, reason in SKIP_FLAGS:
        if flag in flags:
            return None, reason, reason
    signature = method.get("Signature")
    if not isinstance(signature, list) or not signature:
        raise InputError(f"method {selector} has no Signature")
    if len(signature) - 1 != selector.count(":"):
        return None, "parameter count does not match selector", "parameter count mismatch"
    try:
        ret = mapper.resolve(signature[0], True)
        args = [mapper.resolve(t, False) for t in signature[1:]]
    except Unsupported as e:
        return None, f"unsupported: {e}", f"unsupported: {e.category}"
    return Stub(binder, selector, is_static, method, ret, args, None), None, None


PREAMBLE = """\
// Generated by scripts/generate-aot.py. Do not edit.
#import <NativeScript/NativeScriptAOT.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef void (*AOTSendFn)(void);

// x86_64 returns a struct through a hidden pointer, and needs the _stret entry
// points, when it is classified MEMORY. Size over 16 bytes approximates that
// classification; smaller structs with unaligned or long double fields are not
// modeled. arm64 never uses _stret.
#if defined(__x86_64__)
#define AOT_SEND_STRET(T) (sizeof(T) > 16 ? (AOTSendFn)objc_msgSend_stret : (AOTSendFn)objc_msgSend)
#define AOT_SEND_SUPER_STRET(T) \\
  (sizeof(T) > 16 ? (AOTSendFn)objc_msgSendSuper_stret : (AOTSendFn)objc_msgSendSuper)
#else
#define AOT_SEND_STRET(T) ((AOTSendFn)objc_msgSend)
#define AOT_SEND_SUPER_STRET(T) ((AOTSendFn)objc_msgSendSuper)
#endif
"""


def gen_external_registration(stubs):
    lines = ['__attribute__((visibility("default")))',
             "void __ns_register_aot_calls(void (*reg)(const char*, const char*, bool,"
             " NSAOTCallHandler)) {"]
    for s in stubs:
        static_str = "true" if s.is_static else "false"
        for cls in s.registrations:
            lines.append(f'  reg("{cls}", "{s.selector}", {static_str}, {s.name});')
    lines.append("}")
    return "\n".join(lines)


def load_config(path):
    try:
        with open(path) as f:
            config = json.load(f)
    except (OSError, ValueError) as e:
        raise InputError(f"cannot read config {path}: {e}")
    methods = config.get("methods") if isinstance(config, dict) else None
    if not isinstance(methods, list):
        raise InputError(f"{path}: expected an object with a \"methods\" array")
    entries = []
    seen = set()
    for i, m in enumerate(methods):
        if not isinstance(m, dict):
            raise InputError(f"{path}: methods[{i}] is not an object")
        cls = m.get("class")
        sel = m.get("selector")
        is_static = m.get("static", False)
        if not isinstance(cls, str) or not cls or not isinstance(sel, str) or not sel:
            raise InputError(f"{path}: methods[{i}] needs non-empty \"class\" and \"selector\" strings")
        if not isinstance(is_static, bool):
            raise InputError(f"{path}: methods[{i}].static must be a boolean")
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_:]*$", sel):
            raise InputError(f"{path}: methods[{i}] has an invalid selector {sel!r}")
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_.$]*$", cls):
            raise InputError(f"{path}: methods[{i}] has an invalid class name {cls!r}")
        key = (cls, sel, is_static)
        if key not in seen:
            seen.add(key)
            entries.append(key)
    return entries


def generate(config_path, metadata_dir, output_path, report):
    entries = load_config(config_path)
    md = Metadata(metadata_dir)
    mapper = TypeMapper(md)

    stubs = []
    by_key = {}
    outcomes = []
    names = set()
    for entry in entries:
        stub, reason, category = plan_entry(md, mapper, entry)
        if stub is not None:
            key = (stub.cls, stub.selector, stub.is_static)
            if key in by_key:
                stub = by_key[key]
            else:
                base = method_stub_name(stub.cls, stub.selector, stub.is_static)
                name = base
                n = 2
                while name in names:
                    name = f"{base}_{n}"
                    n += 1
                names.add(name)
                stub.name = name
                by_key[key] = stub
                stubs.append(stub)
            # The runtime binds at the declaring class; the config name is
            # registered too so a lookup keyed on it also resolves.
            for cls in (stub.cls, entry[0]):
                if cls not in stub.registrations:
                    stub.registrations.append(cls)
            reason = None
            category = stub.cls
        outcomes.append((entry, reason, category))

    parts = [PREAMBLE]
    typedefs = mapper.emit_typedefs()
    if typedefs:
        parts.append("\n".join(typedefs) + "\n")
    for s in stubs:
        parts.append(s.emit() + "\n")
    parts.append(gen_external_registration(stubs) + "\n")

    out_dir = os.path.dirname(os.path.abspath(output_path))
    os.makedirs(out_dir, exist_ok=True)
    with open(output_path, "w") as f:
        f.write("\n".join(parts))

    skipped = [o for o in outcomes if o[1] is not None]
    for (cls, sel, is_static), reason, detail in outcomes if report else skipped:
        prefix = "+" if is_static else "-"
        if reason is not None:
            status = f"skipped: {reason}"
        elif detail == cls:
            status = "generated"
        else:
            status = f"generated, declared on {detail}"
        print(f"{prefix}[{cls} {sel}] {status}")
    print(f"wrote {output_path}")
    print(f"generated {len(outcomes) - len(skipped)} entries as {len(stubs)} stubs, skipped {len(skipped)}")
    by_category = {}
    for _entry, _reason, category in skipped:
        by_category[category] = by_category.get(category, 0) + 1
    for category, n in sorted(by_category.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"  {n:4d}  {category}")


def main(argv):
    parser = argparse.ArgumentParser(
        description="Generate NativeScript AOT call stubs from an AOT config and metadata JSON.")
    parser.add_argument("config", help="AOT config JSON ({\"methods\": [...]})")
    parser.add_argument("-m", "--metadata", required=True,
                        help="directory of <Module>.json files from the metadata generator's -output-json")
    parser.add_argument("-o", "--output", default="NativeScriptAOTStubs.m",
                        help="output Objective-C file (default: %(default)s)")
    parser.add_argument("--report", action="store_true",
                        help="list the outcome of every config entry")
    args = parser.parse_args(argv)
    try:
        generate(args.config, args.metadata, args.output, args.report)
    except InputError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
