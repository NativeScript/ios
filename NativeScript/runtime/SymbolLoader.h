#ifndef SymbolLoader_h
#define SymbolLoader_h

#include <map>
#include "Metadata.h"

namespace tns {

class SymbolResolver;

class SymbolLoader {
public:
    static SymbolLoader& instance();

    void* loadFunctionSymbol(const ModuleMeta*, const char* symbolName);
    void* loadDataSymbol(const ModuleMeta*, const char* symbolName);
    bool ensureModule(const ModuleMeta*);

private:
    SymbolResolver* resolveModule(const ModuleMeta*);

    std::map<const ModuleMeta*, std::unique_ptr<SymbolResolver>> _cache;
};

}

#endif /* SymbolLoader_h */
