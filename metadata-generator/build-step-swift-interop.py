#!/usr/bin/env python3

# Generates and compiles the Swift interop thunks (ns:swift) for an app's
# Swift modules, for one architecture. Run by internal/nsld.sh from the
# metadata generator's bin folder, after the app's Swift code is compiled.
#
# NS_SWIFT_MODULES names the Swift modules JavaScript uses, space-separated:
# SDK modules (WeatherKit), SwiftPM packages and the app's own module. They are
# generated as one unit. The script writes the object file and the extra
# linker arguments, one per line, to
# $CONFIGURATION_BUILD_DIR/NSSwiftInterop-<arch>/link-arguments.txt. When the
# extracted symbol graphs, the generator and the settings are unchanged, the
# previous object is reused.
#
# Optional settings:
#   NS_SWIFT_UNIT                  unit name (default: <product module>Swift)
#   NS_SWIFT_VERIFY                NO skips compiler verification of the surface
#   NS_TYPESCRIPT_DECLARATIONS_PATH  also writes swift!<Module>.d.ts there

import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys


def env(name, default=""):
    return os.environ.get(name, default)


def run(command, log):
    print(" ".join(shlex.quote(part) for part in command))
    sys.stdout.flush()
    with open(log, "w") as output:
        status = subprocess.call(command, stdout=output, stderr=subprocess.STDOUT)
    if status != 0:
        with open(log) as output:
            print(output.read())
        print("error: Swift interop: {} failed (see {})".format(command[0], log))
        sys.exit(status)


def main(arch):
    modules = env("NS_SWIFT_MODULES").split()
    work = os.path.join(env("CONFIGURATION_BUILD_DIR"), "NSSwiftInterop-" + arch)
    arguments_file = os.path.join(work, "link-arguments.txt")
    key_file = os.path.join(work, "cache-key.txt")
    for stale in ("graphs", "verify"):
        shutil.rmtree(os.path.join(work, stale), ignore_errors=True)
    os.makedirs(work, exist_ok=True)
    if not modules:
        open(arguments_file, "w").close()
        return

    sdk = env("SDKROOT")
    deployment = env(env("DEPLOYMENT_TARGET_CLANG_ENV_NAME", "IPHONEOS_DEPLOYMENT_TARGET")) or \
        env("IPHONEOS_DEPLOYMENT_TARGET")
    os_name = env("SWIFT_PLATFORM_TARGET_PREFIX", "ios")
    target = "{}-{}-{}{}{}".format(arch, env("LLVM_TARGET_TRIPLE_VENDOR", "apple"), os_name,
                                   deployment, env("LLVM_TARGET_TRIPLE_SUFFIX"))

    # Build settings hold paths relative to the project; this runs elsewhere.
    def resolve(paths):
        resolved = []
        for path in paths:
            path = os.path.normpath(os.path.join(env("SRCROOT"), path))
            if path not in resolved:
                resolved.append(path)
        return resolved

    # Where the app's module, its packages' modules and the clang modules
    # they import (plugin sources' module maps) are.
    search = [env("CONFIGURATION_BUILD_DIR"), env("BUILT_PRODUCTS_DIR")]
    if env("OBJECT_FILE_DIR_normal"):
        search.append(os.path.join(env("OBJECT_FILE_DIR_normal"), arch))
    for setting in ("SWIFT_INCLUDE_PATHS", "HEADER_SEARCH_PATHS", "USER_HEADER_SEARCH_PATHS"):
        search += shlex.split(env(setting))
    search = resolve(path for path in search if path)
    frameworks = resolve(shlex.split(env("FRAMEWORK_SEARCH_PATHS")) +
                         [os.path.join(sdk, "System/Library/SubFrameworks")])
    search_flags = [flag for path in search for flag in ("-I", path)] + \
        [flag for path in frameworks for flag in ("-F", path)]

    graph_dirs = []
    for module in modules:
        output = os.path.join(work, "graphs", module)
        os.makedirs(output)
        run(["xcrun", "swift-symbolgraph-extract", "-module-name", module, "-target", target,
             "-sdk", sdk, "-minimum-access-level", "public", "-output-dir", output] + search_flags,
            os.path.join(work, "symbolgraph-" + module + ".log"))
        graph_dirs.append(output)

    unit = env("NS_SWIFT_UNIT") or (env("PRODUCT_MODULE_NAME", "App") + "Swift")
    generator = ["./objc-metadata-generator", "--skip-objc", "--swift-unit", unit,
                 "--swift-deployment-target", deployment, "--swift-thunk-output", work,
                 "--swift-coverage-output", work]
    for directory in graph_dirs:
        generator += ["--swift-symbolgraph-dir", directory]
    if env("NS_SWIFT_VERIFY").upper() not in ("NO", "FALSE", "0"):
        generator += ["--swift-verify", "--swift-sdk", sdk, "--swift-target", target,
                      "--swift-work-dir", os.path.join(work, "verify")]
        generator += [flag for path in search for flag in ("--swift-search-path", path)]
        generator += [flag for path in frameworks for flag in ("--swift-framework-search-path", path)]
    declarations = env("NS_TYPESCRIPT_DECLARATIONS_PATH")
    if declarations:
        generator += ["-output-typescript", os.path.join(declarations, "swift")]
    thunks = os.path.join(work, unit + "+NativeScript.swift")
    obj = os.path.join(work, unit + "+NativeScript.o")
    optimization = "-Onone" if env("CONFIGURATION") == "Debug" else "-O"
    compile = ["xcrun", "swiftc", "-parse-as-library", "-c", thunks, "-o", obj,
               "-module-name", "NSSwiftInterop" + unit, "-target", target, "-sdk", sdk,
               "-swift-version", "5", optimization] + search_flags

    # Everything the object depends on.
    digest = hashlib.sha256()
    for directory in graph_dirs:
        for name in sorted(os.listdir(directory)):
            with open(os.path.join(directory, name), "rb") as graph:
                digest.update(name.encode() + graph.read())
    tool = os.stat("./objc-metadata-generator")
    digest.update(json.dumps([generator, compile, tool.st_size, tool.st_mtime,
                              os.stat(__file__).st_mtime]).encode())
    key = digest.hexdigest()
    previous = open(key_file).read() if os.path.exists(key_file) else ""
    if previous == key and os.path.exists(obj):
        print("Swift interop: {} is up to date".format(obj))
    else:
        if os.path.exists(key_file):
            os.remove(key_file)
        run(generator + ["Xclang"], os.path.join(work, "generator.log"))
        run(compile, os.path.join(work, "swiftc.log"))
        with open(key_file, "w") as output:
            output.write(key)

    with open(arguments_file, "w") as output:
        output.write(obj + "\n")
        # Keeps the register functions, which only the runtime's dlsym
        # references.
        for module in modules:
            output.write("-Wl,-u,_ns_swift_register_" + module + "\n")
    print("Swift interop: {} for {}".format(obj, " ".join(modules)))


if __name__ == "__main__":
    main(sys.argv[1])
