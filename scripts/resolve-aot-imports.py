#!/usr/bin/env python3
"""
Resolve framework imports for an AOT config file.

Scans metadata output (JSON or YAML, from the NativeScript metadata generator)
to find which framework each class in aot-config.json belongs to, then writes
the "imports" array back into the config. Prompts interactively when a class
name is defined in multiple frameworks.

Usage:
    python3 scripts/resolve-aot-imports.py <metadata_dir> [config.json]

    metadata_dir — directory containing <Framework>.json (or .yaml) files from
                   the metadata generator (--output-json / --output-yaml flags,
                   or NS_DEBUG_METADATA_PATH env var)
    config.json  — path to aot-config.json (default: aot-config.json in project root)

The script only modifies the "imports" field. All other fields are preserved.
JSON metadata files are preferred over YAML when both are present.
"""

import glob
import json
import os
import re
import sys


class InterfaceInfo:
    __slots__ = ("name", "js_name", "filename", "static_selectors", "instance_selectors")
    def __init__(self, name, js_name, filename):
        self.name = name
        self.js_name = js_name
        self.filename = filename
        self.static_selectors = set()
        self.instance_selectors = set()


class ModuleInfo:
    __slots__ = ("name", "is_framework", "is_system", "interfaces")
    def __init__(self, name, is_framework, is_system):
        self.name = name
        self.is_framework = is_framework
        self.is_system = is_system
        self.interfaces = []


def parse_yaml(yaml_path):
    """Extract module info and top-level Interface entries from a metadata YAML file."""
    module = ModuleInfo(None, False, False)

    current_iface = None  # InterfaceInfo being built
    current_name = None
    current_js_name = None
    current_filename = None
    # Which section of an interface we're in
    in_section = None  # "instance", "static", or None

    with open(yaml_path, errors="replace") as f:
        for line in f:
            # Module header fields (2-space indent, before Items)
            m = re.match(r"^  FullName:\s+(\S+)", line)
            if m and module.name is None:
                module.name = m.group(1)
                continue

            m = re.match(r"^  IsPartOfFramework:\s+(true|false)", line)
            if m and not module.is_framework:
                module.is_framework = m.group(1) == "true"
                continue

            m = re.match(r"^  IsSystemModule:\s+(true|false)", line)
            if m and not module.is_system:
                module.is_system = m.group(1) == "true"
                continue

            # Top-level item: "  - Name:" (2-space indent)
            m = re.match(r"^  - Name:\s+(.+)$", line)
            if m:
                current_iface = None
                in_section = None
                current_name = m.group(1).strip().strip("'\"")
                current_js_name = None
                current_filename = None
                continue

            if current_name is not None and current_iface is None:
                m = re.match(r"^    JsName:\s+(.+)$", line)
                if m:
                    current_js_name = m.group(1).strip().strip("'\"")
                    continue

                m = re.match(r"^    Filename:\s+'?(.+?)'?\s*$", line)
                if m:
                    current_filename = m.group(1)
                    continue

                m = re.match(r"^    Type:\s+(\S+)", line)
                if m:
                    if m.group(1) == "Interface":
                        current_iface = InterfaceInfo(
                            current_name,
                            current_js_name or current_name,
                            current_filename,
                        )
                        module.interfaces.append(current_iface)
                    else:
                        current_name = None
                    continue

                if re.match(r"^  - ", line):
                    current_name = None
                    current_js_name = None
                    current_filename = None
                    continue

            # Inside an interface — parse method sections
            if current_iface is not None:
                # Section transition detection.
                # Real section headers are at exactly 4-space indent:
                #     InstanceMethods:
                #     StaticMethods:
                #     InstanceProperties:
                # But the metadata generator also emits them embedded in the
                # *last* method's Signature type list like:
                #           - Type:            StaticMethods:
                # We detect both forms for method sections, but only reset
                # on 4-space properties/protocols to avoid false matches
                # with "WithProtocols:" etc.
                if re.match(r"^    InstanceMethods:", line) or \
                        re.match(r"^.*- Type:\s+InstanceMethods:", line):
                    in_section = "instance"
                    pending_method_name = None
                    continue
                if re.match(r"^    StaticMethods:", line) or \
                        re.match(r"^.*- Type:\s+StaticMethods:", line):
                    if "[]" not in line:
                        in_section = "static"
                        pending_method_name = None
                        continue
                if re.match(r"^    (InstanceProperties|StaticProperties|Protocols):", line):
                    in_section = None
                    pending_method_name = None
                    continue
                # Next top-level item — done with this interface
                if re.match(r"^  - Name:", line):
                    current_iface = None
                    in_section = None
                    pending_method_name = None
                    current_name = line.split("Name:", 1)[1].strip().strip("'\"")
                    current_js_name = None
                    current_filename = None
                    continue

                if in_section in ("instance", "static"):
                    # Method entry at 6-space indent: "      - Name:"
                    m = re.match(r"^      - Name:\s+(.+)$", line)
                    if m:
                        pending_method_name = m.group(1).strip().strip("'\"")
                        continue

                    # Confirm it's actually a Method (not Property)
                    if pending_method_name is not None:
                        m = re.match(r"^        Type:\s+(\S+)", line)
                        if m:
                            if m.group(1) == "Method":
                                if in_section == "static":
                                    current_iface.static_selectors.add(pending_method_name)
                                else:
                                    current_iface.instance_selectors.add(pending_method_name)
                            pending_method_name = None
                            continue
                        # Another entry started without seeing Type
                        if re.match(r"^      - Name:", line):
                            pending_method_name = line.split("Name:", 1)[1].strip().strip("'\"")
                            continue

    return module


def parse_json_file(json_path):
    """Extract module info and Interface entries from a metadata JSON file."""
    with open(json_path) as f:
        data = json.load(f)

    mod_data = data.get("Module", {})
    module = ModuleInfo(
        mod_data.get("FullName"),
        mod_data.get("IsPartOfFramework", False),
        mod_data.get("IsSystemModule", False),
    )

    for item in data.get("Items", []):
        if item.get("Type") != "Interface":
            continue
        name = item.get("Name", "")
        js_name = item.get("JsName", name)
        filename = item.get("Filename", "")
        iface = InterfaceInfo(name, js_name, filename)

        for m in item.get("StaticMethods", []):
            if m.get("Type") == "Method":
                iface.static_selectors.add(m["Name"])
        for m in item.get("InstanceMethods", []):
            if m.get("Type") == "Method":
                iface.instance_selectors.add(m["Name"])

        module.interfaces.append(iface)

    return module


def _collect_protocol_names_json(json_path):
    """Extract Protocol names from a metadata JSON file."""
    names = set()
    with open(json_path) as f:
        data = json.load(f)
    for item in data.get("Items", []):
        if item.get("Type") == "Protocol":
            names.add(item.get("Name", ""))
            js = item.get("JsName", "")
            if js:
                names.add(js)
    names.discard("")
    return names


def _collect_protocol_names_yaml(yaml_path):
    """Extract Protocol names from a metadata YAML file."""
    names = set()
    current_name = None
    current_js_name = None
    with open(yaml_path, errors="replace") as f:
        for line in f:
            m = re.match(r"^  - Name:\s+(.+)$", line)
            if m:
                current_name = m.group(1).strip().strip("'\"")
                current_js_name = None
                continue
            if current_name is not None:
                m = re.match(r"^    JsName:\s+(.+)$", line)
                if m:
                    current_js_name = m.group(1).strip().strip("'\"")
                    continue
                m = re.match(r"^    Type:\s+(\S+)", line)
                if m:
                    if m.group(1) == "Protocol":
                        names.add(current_name)
                        if current_js_name:
                            names.add(current_js_name)
                    current_name = None
                    current_js_name = None
                    continue
    return names


def scan_metadata_dir(metadata_dir):
    """Build lookup maps from all JSON or YAML files.

    Prefers JSON files when present; falls back to YAML.

    Returns:
        (name_to_entries, protocol_names)
        name_to_entries: dict mapping Name or JsName → [(ModuleInfo, InterfaceInfo), ...]
        protocol_names: set of protocol type names
    """
    name_to_entries = {}
    protocol_names = set()

    json_files = sorted(glob.glob(os.path.join(metadata_dir, "*.json")))
    yaml_files = sorted(glob.glob(os.path.join(metadata_dir, "*.yaml")))

    if json_files:
        files_and_parser = [(p, parse_json_file) for p in json_files]
        proto_collector = _collect_protocol_names_json
    elif yaml_files:
        files_and_parser = [(p, parse_yaml) for p in yaml_files]
        proto_collector = _collect_protocol_names_yaml
    else:
        return name_to_entries, protocol_names

    for path, parser in files_and_parser:
        if os.path.basename(path).startswith("metadata-generation"):
            continue
        module = parser(path)
        if not module.name:
            continue
        for iface in module.interfaces:
            entry = (module, iface)
            name_to_entries.setdefault(iface.name, []).append(entry)
            if iface.js_name != iface.name:
                name_to_entries.setdefault(iface.js_name, []).append(entry)
        protocol_names.update(proto_collector(path))

    return name_to_entries, protocol_names


def pick_module(cls, entries):
    """Given multiple (ModuleInfo, InterfaceInfo) entries, pick or prompt."""
    # Deduplicate by module name
    seen = {}
    for mod, iface in entries:
        if mod.name not in seen:
            seen[mod.name] = (mod, iface)
    unique = sorted(seen.values(), key=lambda x: x[0].name)

    if len(unique) == 1:
        return unique[0]

    # Prefer framework modules
    frameworks = [(m, i) for m, i in unique if m.is_framework]
    if len(frameworks) == 1:
        return frameworks[0]

    candidates = frameworks if frameworks else unique
    if len(candidates) == 1:
        return candidates[0]

    print(f"\n  {cls} found in multiple modules:")
    for idx, (mod, iface) in enumerate(candidates):
        tags = []
        if mod.is_framework:
            tags.append("framework")
        if mod.is_system:
            tags.append("system")
        tag_str = f" ({', '.join(tags)})" if tags else ""
        print(f"    [{idx + 1}] {mod.name}{tag_str}")
    while True:
        try:
            choice = input(f"  Choose module for {cls} [1-{len(candidates)}]: ").strip()
            idx = int(choice) - 1
            if 0 <= idx < len(candidates):
                return candidates[idx]
        except (ValueError, EOFError):
            pass
        print("  Invalid choice, try again.")


def import_for_swift(iface):
    """Derive the import directive for a Swift class from its Filename."""
    if not iface.filename:
        return None
    # Swift bridging headers look like: .../Objects-normal/arch/<AppName>-Swift.h
    basename = os.path.basename(iface.filename)
    if basename.endswith("-Swift.h"):
        return f'#import "{basename}"'
    return None


def import_for_framework(mod, iface):
    """Derive the framework import for an interface.

    For non-system frameworks, uses the specific header from the Filename field
    (e.g. #import <TNSListView/TKCollectionView.h>) since they may not have an
    umbrella header. System frameworks always use the umbrella header.
    """
    if mod.is_system:
        return f"#import <{mod.name}/{mod.name}.h>"
    if iface.filename:
        m = re.search(r'\.framework/Headers/(.+\.h)$', iface.filename)
        if m:
            return f"#import <{mod.name}/{m.group(1)}>"
    return f"#import <{mod.name}/{mod.name}.h>"


def resolve(config_path, yaml_dir):
    with open(config_path) as f:
        config = json.load(f)

    methods = config.get("methods", [])
    seen = set()
    deduped = []
    for m in methods:
        key = (m["class"], m["selector"])
        if key not in seen:
            seen.add(key)
            deduped.append(m)
    if len(deduped) < len(methods):
        print(f"  Removed {len(methods) - len(deduped)} duplicate method entries.")
        methods = deduped
        config["methods"] = methods
    class_names = sorted(set(m["class"] for m in methods))

    if not class_names:
        print("No methods in config, nothing to resolve.")
        return

    print(f"Scanning {yaml_dir} for {len(class_names)} classes...")
    name_to_entries, protocol_names = scan_metadata_dir(yaml_dir)

    needed_imports = set()
    unresolved = []
    swift_classes = set()
    resolved_ifaces = {}

    for cls in class_names:
        entries = name_to_entries.get(cls, [])
        if not entries:
            unresolved.append(cls)
            continue

        mod, iface = pick_module(cls, entries)
        resolved_ifaces[cls] = iface

        if import_for_swift(iface):
            swift_classes.add(cls)
            print(f"  {cls} → {mod.name} (Swift class, resolved via objc_getClass)")
        elif mod.name == "Foundation":
            print(f"  {cls} → Foundation (always included)")
        elif mod.is_system and not mod.is_framework:
            print(f"  {cls} → {mod.name} (non-framework system, covered by Foundation)")
        elif mod.is_framework:
            imp = import_for_framework(mod, iface)
            needed_imports.add(imp)
            print(f"  {cls} → {mod.name} ({imp})")
        else:
            needed_imports.add(f"#import <{mod.name}.h>")
            print(f"  {cls} → {mod.name} (non-framework)")

    if unresolved:
        print(f"\n  Warning: could not find these classes in metadata YAML:")
        for cls in unresolved:
            print(f"    - {cls}")

    # Detect ObjC object types used in args/ret that aren't primitives.
    # Types found as Interface in metadata are objects (passed as id),
    # everything else unknown is treated as a struct by the generator.
    PRIMITIVE_TYPES = {
        "void", "BOOL", "id", "instancetype", "NSString", "SEL", "Class",
        "int", "uint", "long", "ulong", "longlong", "ulonglong",
        "float", "double", "char", "uchar", "short", "ushort",
    }
    all_types = set()
    for m in methods:
        all_types.add(m["ret"])
        all_types.update(m["args"])
    unknown_types = all_types - PRIMITIVE_TYPES
    object_types = set()
    for t in sorted(unknown_types):
        if t in name_to_entries:
            object_types.add(t)
    if object_types:
        print(f"\n  Object types (not structs): {', '.join(sorted(object_types))}")

    used_protocols = set(c for c in class_names if c in protocol_names)
    if used_protocols:
        print(f"\n  Protocol types (use objc_msgSend): {', '.join(sorted(used_protocols))}")

    # Detect static methods
    changed = False
    static_changes = []

    for m in methods:
        cls = m["class"]
        iface = resolved_ifaces.get(cls)
        if iface is None:
            continue

        sel = m["selector"]
        is_currently_static = m.get("static", False)

        if sel in iface.static_selectors and not is_currently_static:
            m["static"] = True
            static_changes.append(f"  {cls}.{sel} → static")
            changed = True
        elif sel in iface.instance_selectors and is_currently_static:
            del m["static"]
            static_changes.append(f"  {cls}.{sel} → instance (was static)")
            changed = True

    imports = sorted(needed_imports)
    swift_list = sorted(swift_classes)

    existing = sorted(config.get("imports", []))
    if imports != existing:
        config["imports"] = imports
        changed = True

    existing_swift = sorted(config.get("swiftClasses", []))
    if swift_list != existing_swift:
        if swift_list:
            config["swiftClasses"] = swift_list
        elif "swiftClasses" in config:
            del config["swiftClasses"]
        changed = True

    obj_list = sorted(object_types)
    existing_obj = sorted(config.get("objectTypes", []))
    if obj_list != existing_obj:
        if obj_list:
            config["objectTypes"] = obj_list
        elif "objectTypes" in config:
            del config["objectTypes"]
        changed = True

    proto_list = sorted(used_protocols)
    existing_proto = sorted(config.get("protocolTypes", []))
    if proto_list != existing_proto:
        if proto_list:
            config["protocolTypes"] = proto_list
        elif "protocolTypes" in config:
            del config["protocolTypes"]
        changed = True

    if not changed:
        print(f"\n  Config already up to date.")
        return

    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")

    if static_changes:
        print(f"\n  Static/instance detection:")
        for s in static_changes:
            print(f"    {s}")
    if imports:
        print(f"\n  Updated imports:")
        for imp in imports:
            print(f"    {imp}")
    else:
        print("\n  All classes are in Foundation (or covered by it), no extra imports needed.")
    print(f"  Wrote {config_path}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <metadata_dir> [config.json]")
        print(f"\n  metadata_dir: directory with metadata JSON or YAML files")
        print(f"                (generated via --output-json/--output-yaml or NS_DEBUG_METADATA_PATH)")
        sys.exit(1)

    yaml_dir = sys.argv[1]
    if not os.path.isdir(yaml_dir):
        print(f"Error: {yaml_dir} is not a directory")
        sys.exit(1)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    config_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(project_root, "aot-config.json")

    resolve(config_path, yaml_dir)
