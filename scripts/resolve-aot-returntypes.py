#!/usr/bin/env python3
"""
Resolve return types in an AOT config file from metadata.

Scans metadata output (JSON or YAML) to find the declared return types for
methods currently marked as "id" in the config, and updates them to the
correct type (e.g. instancetype, NSString).

Usage:
    python3 scripts/resolve-aot-returntypes.py <metadata_dir> [config.json]
"""

import glob
import json
import os
import re
import sys

# Metadata return type -> AOT config type.
# Only types that differ from "id" need to be listed here.
RETURN_TYPE_MAP = {
    "Instancetype": "instancetype",
    "NSString": "NSString",
}


def _resolve_ret_type(sig_entry):
    """Extract the effective return type name from a metadata signature entry.

    Unwraps Nullable/NonNullable wrappers and returns a string like
    "Instancetype", "NSString", "Id", "Interface:UIView", etc.
    """
    t = sig_entry.get("Type", "")

    # Unwrap nullability wrappers
    if t in ("Nullable", "NonNullable"):
        inner = sig_entry.get("InnerType", {})
        return _resolve_ret_type(inner)

    if t == "Instancetype":
        return "Instancetype"

    if t == "Interface":
        name = sig_entry.get("Name", "")
        return name if name else "id"

    return t


def scan_yaml_for_methods(yaml_path):
    """Extract method return types from a metadata YAML file.

    Returns dict: (class_name, selector) -> resolved_type_str
    """
    methods = {}
    current_class = None
    current_class_name = None
    in_section = None
    pending_method_name = None
    pending_method_type = None
    reading_signature = False
    # Collect the full first signature entry (return type) across lines
    sig_lines = []
    first_entry_done = False

    with open(yaml_path, errors="replace") as f:
        for line in f:
            # Top-level item
            m = re.match(r"^  - Name:\s+(.+)$", line)
            if m:
                current_class_name = m.group(1).strip().strip("'\"")
                current_class = None
                in_section = None
                pending_method_name = None
                reading_signature = False
                continue

            if current_class_name and current_class is None:
                m = re.match(r"^    Type:\s+(\S+)", line)
                if m:
                    if m.group(1) == "Interface":
                        current_class = current_class_name
                    else:
                        current_class_name = None
                    continue

            if current_class is None:
                continue

            # Section headers
            if re.match(r"^    InstanceMethods:", line) or \
                    re.match(r"^.*- Type:\s+InstanceMethods:", line):
                in_section = "instance"
                pending_method_name = None
                reading_signature = False
                continue
            if re.match(r"^    StaticMethods:", line) or \
                    re.match(r"^.*- Type:\s+StaticMethods:", line):
                if "[]" not in line:
                    in_section = "static"
                    pending_method_name = None
                    reading_signature = False
                    continue
            if re.match(r"^    (InstanceProperties|StaticProperties|Protocols):", line):
                in_section = None
                pending_method_name = None
                reading_signature = False
                continue

            # Next top-level item
            if re.match(r"^  - Name:", line):
                current_class = None
                current_class_name = line.split("Name:", 1)[1].strip().strip("'\"")
                in_section = None
                pending_method_name = None
                reading_signature = False
                continue

            if in_section not in ("instance", "static"):
                continue

            # Method entry
            m = re.match(r"^      - Name:\s+(.+)$", line)
            if m:
                pending_method_name = m.group(1).strip().strip("'\"")
                pending_method_type = None
                reading_signature = False
                continue

            if pending_method_name:
                m = re.match(r"^        Type:\s+(\S+)", line)
                if m:
                    pending_method_type = m.group(1)
                    continue

                if re.match(r"^        Signature:", line):
                    reading_signature = True
                    first_entry_done = False
                    sig_lines = []
                    continue

                if reading_signature and not first_entry_done:
                    # Detect the start of the first entry
                    m = re.match(r"^(\s+)- Type:\s+(\S+)", line)
                    if m:
                        if sig_lines:
                            # We hit the SECOND entry — flush the first
                            ret_type = _parse_yaml_sig_entry(sig_lines)
                            if pending_method_type == "Method":
                                methods[(current_class, pending_method_name)] = ret_type
                            first_entry_done = True
                            reading_signature = False
                            pending_method_name = None
                            continue
                        sig_lines.append(line)
                        continue
                    if sig_lines:
                        sig_lines.append(line)
                    continue

    return methods


def _parse_yaml_sig_entry(lines):
    """Parse collected YAML lines for one signature entry into a type string."""
    top_type = None
    inner_type = None
    inner_name = None

    for line in lines:
        m = re.match(r"^\s+- Type:\s+(\S+)", line)
        if m and top_type is None:
            top_type = m.group(1).rstrip(":")
            continue
        m = re.match(r"^\s+Type:\s+(\S+)", line)
        if m:
            inner_type = m.group(1).rstrip(":")
            continue
        m = re.match(r"^\s+Name:\s+(\S+)", line)
        if m and inner_name is None:
            inner_name = m.group(1).strip().strip("'\"")
            continue

    if top_type in ("Nullable", "NonNullable"):
        if inner_type == "Interface" and inner_name:
            return inner_name
        if inner_type == "Instancetype":
            return "Instancetype"
        return inner_type or top_type

    if top_type == "Interface" and inner_name:
        return inner_name
    if top_type == "Instancetype":
        return "Instancetype"
    return top_type or ""


def scan_json_for_methods(json_path):
    """Extract method return types from a metadata JSON file."""
    methods = {}
    with open(json_path) as f:
        data = json.load(f)

    for item in data.get("Items", []):
        if item.get("Type") != "Interface":
            continue
        cls = item.get("Name", "")

        for section in ("StaticMethods", "InstanceMethods"):
            for m in item.get(section, []):
                if m.get("Type") != "Method":
                    continue
                sel = m.get("Name", "")
                sig = m.get("Signature", [])
                if sig:
                    methods[(cls, sel)] = _resolve_ret_type(sig[0])

    return methods


def scan_metadata_dir(metadata_dir):
    """Scan all metadata files and build (class, selector) -> return_type map."""
    all_methods = {}

    json_files = sorted(glob.glob(os.path.join(metadata_dir, "*.json")))
    yaml_files = sorted(glob.glob(os.path.join(metadata_dir, "*.yaml")))

    if json_files:
        files_and_parser = [(p, scan_json_for_methods) for p in json_files]
    elif yaml_files:
        files_and_parser = [(p, scan_yaml_for_methods) for p in yaml_files]
    else:
        return all_methods

    for path, parser in files_and_parser:
        if os.path.basename(path).startswith("metadata-generation"):
            continue
        methods = parser(path)
        all_methods.update(methods)

    return all_methods


def resolve(config_path, metadata_dir):
    with open(config_path) as f:
        config = json.load(f)

    methods = config.get("methods", [])
    if not methods:
        print("No methods in config.")
        return

    print(f"Scanning {metadata_dir} for return types...")
    meta_methods = scan_metadata_dir(metadata_dir)
    print(f"  Found {len(meta_methods)} methods in metadata.")

    changes = []
    for m in methods:
        cls = m["class"]
        sel = m["selector"]
        ret = m.get("ret", "")

        if ret != "id":
            continue

        meta_ret = meta_methods.get((cls, sel))
        if meta_ret is None:
            continue

        new_ret = RETURN_TYPE_MAP.get(meta_ret)
        if new_ret:
            m["ret"] = new_ret
            changes.append(f"  {cls}.{sel}: id -> {new_ret} (metadata: {meta_ret})")

    if not changes:
        print("No changes needed.")
        return

    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")

    print(f"\nUpdated {len(changes)} methods:")
    for c in changes:
        print(c)
    print(f"Wrote {config_path}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <metadata_dir> [config.json]")
        sys.exit(1)

    metadata_dir = sys.argv[1]
    if not os.path.isdir(metadata_dir):
        print(f"Error: {metadata_dir} is not a directory")
        sys.exit(1)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    config_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(project_root, "aot-config.json")

    resolve(config_path, metadata_dir)
