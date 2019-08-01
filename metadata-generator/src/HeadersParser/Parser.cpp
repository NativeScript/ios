#include "Parser.h"

#include <clang/Frontend/ASTUnit.h>
#include <clang/Lex/HeaderSearch.h>
#include <clang/Lex/Preprocessor.h>
#include <clang/Tooling/Tooling.h>
#include <iostream>
#include <sstream>
#include <llvm/ADT/StringSwitch.h>
#include <llvm/Support/Path.h>

using namespace clang;
namespace path = llvm::sys::path;
namespace fs = llvm::sys::fs;

static std::error_code addHeaderInclude(StringRef headerName, std::vector<SmallString<256>>& includes)
{

    // Use an absolute path for the include; there's no reason to think whether a relative path will
    // work ('.' might not be on our include path) or that it will find the same file.
    if (path::is_absolute(headerName)) {
        includes.push_back(headerName);
    }
    else {
        SmallString<256> header = headerName;
        if (std::error_code err = fs::make_absolute(header))
            return err;
        includes.push_back(header);
    }

    return std::error_code();
}

static std::error_code addHeaderInclude(const FileEntry* header, std::vector<SmallString<256>>& includes)
{
    return addHeaderInclude(header->getName(), includes);
}

static std::error_code collectModuleHeaderIncludes(FileManager& fileMgr, ModuleMap& modMap, const Module* module, std::vector<SmallString<256>>& includes)
{
    // Don't collect any headers for unavailable modules.
    if (!module->isAvailable())
        return std::error_code();

    if (const FileEntry* umbrellaHeader = module->getUmbrellaHeader().Entry) {
        if (std::error_code err = addHeaderInclude(umbrellaHeader, includes))
            return err;
    }
    else if (const DirectoryEntry* umbrellaDir = module->getUmbrellaDir().Entry) {
        // Add all of the headers we find in this subdirectory.
        std::error_code ec;
        SmallString<128> dirNative;
        path::native(umbrellaDir->getName(), dirNative);
        for (fs::recursive_directory_iterator dir(dirNative.str(), ec), dirEnd; dir != dirEnd && !ec; dir.increment(ec)) {
            // Check whether this entry has an extension typically associated with headers.
            if (!llvm::StringSwitch<bool>(path::extension(dir->path()))
                     .Cases(".h", ".H", true)
                     .Default(false))
                continue;

            // If this header is marked 'unavailable' in this module, don't include it.
            if (const FileEntry* header = fileMgr.getFile(dir->path())) {
                if (modMap.isHeaderUnavailableInModule(header, module))
                    continue;

                addHeaderInclude(header, includes);
            }

            // Include this header as part of the umbrella directory.
            if (auto err = addHeaderInclude(dir->path(), includes))
                return err;
        }

        if (ec)
            return ec;
    } else {
        for (auto header : module->Headers[Module::HK_Normal]) {
            if (auto err = addHeaderInclude(header.Entry, includes))
                return err;
        }
    }

    return std::error_code();
}

static std::error_code CreateUmbrellaHeaderForAmbientModules(const std::vector<std::string>& args, std::vector<SmallString<256>>& umbrellaHeaders, const std::vector<std::string>& moduleBlacklist, std::vector<std::string>& includePaths)
{
    std::unique_ptr<clang::ASTUnit> ast = clang::tooling::buildASTFromCodeWithArgs("", args, "umbrella.h");
    if (!ast)
        return std::error_code(-1, std::generic_category());
    
    ast->getDiagnostics().setClient(new clang::IgnoringDiagConsumer);
    
    clang::SmallVector<clang::Module*, 64> modules;
    HeaderSearch& headerSearch = ast->getPreprocessor().getHeaderSearchInfo();
    headerSearch.collectAllModules(modules);
    
    ModuleMap& moduleMap = headerSearch.getModuleMap();
    FileManager& fileManager = ast->getFileManager();
    
    std::function<void(const Module*)> collector = [&](const Module* module) {
        // uncomment for debugging unavailable modules
//        if (!module->isAvailable()) {
//            clang::Module::Requirement req;
//            clang::Module::UnresolvedHeaderDirective h;
//            clang::Module* sm;
//            module->isAvailable(ast->getPreprocessor().getLangOpts(), ast->getPreprocessor().getTargetInfo(), req, h, sm);
//        }
        if (std::find(moduleBlacklist.begin(), moduleBlacklist.end(), module->getFullModuleName()) != moduleBlacklist.end())
            return;
        
        // use -idirafter instead of -I in order  add the directories AFTER the include search paths
        std::string includeString = "-idirafter" + module->Directory->getName().str();
        if (std::find(includePaths.begin(), includePaths.end(), includeString) == includePaths.end() && !module->isPartOfFramework()) {
            includePaths.push_back(includeString);
        }
        
        collectModuleHeaderIncludes(fileManager, moduleMap, module, umbrellaHeaders);
        std::for_each(module->submodule_begin(), module->submodule_end(), collector);
    };
    
    std::for_each(modules.begin(), modules.end(), collector);
    
    return std::error_code();
}

// Sort headers so that -Swift headers come last (see https://github.com/NativeScript/ios-runtime/issues/1153)
int headerPriority(SmallString<256> h) {
    if (std::string::npos != h.find("-Swift")) {
        return 1;
    } else {
        return 0;
    }
}


std::string CreateUmbrellaHeader(const std::vector<std::string>& clangArgs, std::vector<std::string>& includePaths)
{
    std::vector<std::string> moduleBlacklist;
    
    // Generate umbrella header for all modules from the sdk
    std::vector<SmallString<256>> umbrellaHeaders;
    CreateUmbrellaHeaderForAmbientModules(clangArgs, umbrellaHeaders, moduleBlacklist, includePaths);
   
    std::sort(umbrellaHeaders.begin(), umbrellaHeaders.end(), [](const SmallString<256>& h1, const SmallString<256>& h2) {
        return headerPriority(h1) < headerPriority(h2);
    });
    
    std::stringstream umbrellaHeaderContents;
    for (auto& h : umbrellaHeaders) {
        umbrellaHeaderContents << "#import \"" << h.c_str() << "\"" << std::endl;
    }

    return umbrellaHeaderContents.str();
}
