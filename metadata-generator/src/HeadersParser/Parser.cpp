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

    if (module->Umbrella && module->Umbrella.is<FileEntryRef>()) {
        const FileEntry* umbrellaHeader = module->Umbrella.get<FileEntryRef>();
        if (std::error_code err = addHeaderInclude(umbrellaHeader, includes))
            return err;
    }
    else if (module->Umbrella && module->Umbrella.is<DirectoryEntryRef>()) {
        const DirectoryEntryRef umbrellaDir = module->Umbrella.get<DirectoryEntryRef>();
        // Add all of the headers we find in this subdirectory.
        std::error_code ec;
        SmallString<128> dirNative;
        path::native(umbrellaDir.getName(), dirNative);
        for (fs::recursive_directory_iterator dir(dirNative.str(), ec), dirEnd; dir != dirEnd && !ec; dir.increment(ec)) {
            // Check whether this entry has an extension typically associated with headers.
            if (!llvm::StringSwitch<bool>(path::extension(dir->path()))
                     .Cases(".h", ".H", true)
                     .Default(false))
                continue;

            // If this header is marked 'unavailable' in this module, don't include it.
            auto header = fileMgr.getFileRef(dir->path());
            if (header) {
                if (modMap.isHeaderUnavailableInModule(*header, module))
                    continue;

                addHeaderInclude(*header, includes);
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

static std::error_code CreateUmbrellaHeaderForAmbientModules(const std::vector<std::string>& args, std::vector<SmallString<256>>& umbrellaHeaders, std::vector<std::string>& includePaths)
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

        // use -idirafter instead of -I in order  add the directories AFTER the include search paths
        std::string includeString = "-idirafter" + module->Directory->getName().str();
        if (std::find(includePaths.begin(), includePaths.end(), includeString) == includePaths.end() && !module->isPartOfFramework()) {
            includePaths.push_back(includeString);
        }

        collectModuleHeaderIncludes(fileManager, moduleMap, module, umbrellaHeaders);
        std::for_each(module->submodules().begin(), module->submodules().end(), collector);
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
    // Generate umbrella header for all modules from the sdk
    std::vector<SmallString<256>> umbrellaHeaders;
    CreateUmbrellaHeaderForAmbientModules(clangArgs, umbrellaHeaders, includePaths);

    std::stable_sort(umbrellaHeaders.begin(), umbrellaHeaders.end(), [](const SmallString<256>& h1, const SmallString<256>& h2) {
        return headerPriority(h1) < headerPriority(h2);
    });

    std::stringstream umbrellaHeaderContents;
    for (auto& h : umbrellaHeaders) {
        umbrellaHeaderContents << "#import \"" << h.c_str() << "\"" << std::endl;
    }

    return umbrellaHeaderContents.str();
}
