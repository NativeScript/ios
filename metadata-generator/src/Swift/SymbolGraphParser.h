#pragma once

#include <string>
#include <unordered_map>
#include <vector>

namespace Meta { class Meta; }

namespace Swift {
struct ModuleGraphs {
    // Module name -> list of file paths (*.symbolgraph and/or *.symbols.json)
    std::unordered_map<std::string, std::vector<std::string>> filesByModule;
};

// Minimal Swift symbolgraph -> Meta bridge
class SymbolGraphParser {
public:
    // Scan a directory for *.symbolgraph or *.symbols.json and group by module
    static ModuleGraphs scanDirectory(const std::string& dirPath);

    // Parse all symbol graph files for a module into Meta objects
    static std::vector<Meta::Meta*> parseModule(const std::string& moduleName,
                                               const std::vector<std::string>& graphFiles);
};
}
