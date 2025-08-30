#include "SymbolGraphParser.h"

#include <fstream>
#include <iostream>
#include <regex>
#include <sstream>

#include "Meta/MetaEntities.h"
#include "Meta/TypeFactory.h"

#include <llvm/Support/FileSystem.h>
#include <llvm/Support/Path.h>
namespace fs = llvm::sys::fs;
namespace path = llvm::sys::path;

namespace Swift {

static bool hasSymbolGraphExt(llvm::StringRef filePath) {
    auto ext = path::extension(filePath);
    return ext == ".symbolgraph" || ext == ".json" || ext == ".symbols"; // allow *.symbols.json
}

ModuleGraphs SymbolGraphParser::scanDirectory(const std::string& dirPath) {
    ModuleGraphs result;
    std::error_code ec;
    if (!fs::exists(dirPath, ec)) {
        return result;
    }

    std::regex moduleHint("([A-Za-z0-9_]+)\\.symbols?\\.json$|([A-Za-z0-9_]+)\\.symbolgraph$");

    for (fs::recursive_directory_iterator it(dirPath, ec), end; it != end && !ec; it.increment(ec)) {
        if (ec) break;
        if (it->type() != fs::file_type::regular_file) continue;
        auto p = it->path();
        if (!hasSymbolGraphExt(p)) continue;

        std::smatch m;
        std::string filename = std::string(path::filename(p));
        std::string module;
        if (std::regex_search(filename, m, moduleHint)) {
            if (m[1].matched) module = m[1].str();
            else if (m[2].matched) module = m[2].str();
        }
        if (module.empty()) {
            module = std::string(path::filename(path::parent_path(p)));
        }
        result.filesByModule[module].push_back(std::string(p));
    }
    return result;
}

// Extremely lightweight JSON helpers (only what we need for skeleton)
static std::string findString(const std::string& json, const std::string& key) {
    // naive: "key":"value"
    auto k = std::string("\"") + key + "\"";
    auto pos = json.find(k);
    if (pos == std::string::npos) return "";
    pos = json.find(':', pos);
    if (pos == std::string::npos) return "";
    pos = json.find('"', pos);
    if (pos == std::string::npos) return "";
    auto end = json.find('"', pos + 1);
    if (end == std::string::npos) return "";
    return json.substr(pos + 1, end - pos - 1);
}

static bool contains(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

std::vector<Meta::Meta*> SymbolGraphParser::parseModule(const std::string& moduleName,
                                                        const std::vector<std::string>& graphFiles) {
    using namespace Meta;
    std::vector<Meta*> metas;
    metas.reserve(128);

    // For the skeleton: detect a few simple symbol kinds and emit placeholder metas.
    for (const auto& f : graphFiles) {
        std::ifstream in(f);
        if (!in.good()) continue;
        std::stringstream buffer; buffer << in.rdbuf();
        auto json = buffer.str();

        // naive scan for "symbol" entries and pick a few kinds
        // e.g., "kind": { "identifier": "swift.class" }, name, module, etc.
        // We'll create InterfaceMeta for class, StructMeta for struct, EnumMeta for enum.

        // This is a placeholder approach; a complete parser should iterate the JSON arrays.
        // We’ll just search by snippets to bootstrap.
        if (contains(json, "swift.class")) {
            auto name = findString(json, "title");
            auto* iface = new InterfaceMeta();
            iface->name = name.empty() ? "SwiftClass" : name;
            iface->jsName = iface->name;
            metas.push_back(iface);
        }
        if (contains(json, "swift.struct")) {
            auto name = findString(json, "title");
            auto* st = new StructMeta();
            st->name = name.empty() ? "SwiftStruct" : name;
            st->jsName = st->name;
            metas.push_back(st);
        }
        if (contains(json, "swift.enum")) {
            auto name = findString(json, "title");
            auto* en = new EnumMeta();
            en->name = name.empty() ? "SwiftEnum" : name;
            en->jsName = en->name;
            metas.push_back(en);
        }
        if (contains(json, "swift.protocol")) {
            auto name = findString(json, "title");
            auto* pr = new ProtocolMeta();
            pr->name = name.empty() ? "SwiftProtocol" : name;
            pr->jsName = pr->name;
            metas.push_back(pr);
        }
    }

    // de-dup very naively by jsName
    std::unordered_map<std::string, Meta*> byName;
    std::vector<Meta*> unique;
    for (auto* m : metas) {
        if (!m) continue;
        if (!byName.count(m->jsName)) {
            byName[m->jsName] = m;
            unique.push_back(m);
        } else {
            delete m; // drop duplicates in bootstrap
        }
    }
    return unique;
}

} // namespace Swift
