#include <clang/Frontend/CompilerInstance.h>
#include <clang/Tooling/Tooling.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Support/Debug.h>
#include <llvm/Support/JSON.h>
#include <llvm/Support/Path.h>
#include <pwd.h>

#include <fstream>
#include <sstream>
#include <string>

#include "Binary/binarySerializer.h"
#include "HeadersParser/Parser.h"
#include "Meta/DeclarationConverterVisitor.h"
#include "Meta/Filters/HandleExceptionalMetasFilter.h"
#include "Meta/Filters/HandleMethodsAndPropertiesWithSameNameFilter.h"
#include "Meta/Filters/MergeCategoriesFilter.h"
#include "Meta/Filters/ModulesBlacklist.h"
#include "Meta/Filters/RemoveDuplicateMembersFilter.h"
#include "Meta/Filters/ResolveGlobalNamesCollisionsFilter.h"
#include "Swift/CapabilityClassifier.h"
#include "Swift/CoverageReport.h"
#include "Swift/ProbeEmitter.h"
#include "Swift/ProbeVerifier.h"
#include "Swift/SymbolGraphLoader.h"
#include "Swift/ThunkEmitter.h"
#include "TypeScript/DefinitionWriter.h"
#include "TypeScript/DocSetManager.h"
#include "TypeScript/SwiftDefinitionWriter.h"
#include "Yaml/YamlSerializer.h"

// Command line parameters
llvm::cl::opt<bool>   cla_verbose("verbose", llvm::cl::desc("Set verbose output mode"), llvm::cl::value_desc("bool"));
llvm::cl::opt<bool>   cla_strictIncludes("strict-includes", llvm::cl::desc("Set strict include headers for diagnostic purposes (usually when some metadata is not generated due to wrong import or include statement)"), llvm::cl::value_desc("bool"));
llvm::cl::opt<string> cla_outputUmbrellaHeaderFile("output-umbrella", llvm::cl::desc("Specify the output umbrella header file"), llvm::cl::value_desc("file_path"));
llvm::cl::opt<string> cla_inputUmbrellaHeaderFile("input-umbrella", llvm::cl::desc("Specify the input umbrella header file"), llvm::cl::value_desc("file_path"));
llvm::cl::opt<string> cla_outputYamlFolder("output-yaml", llvm::cl::desc("Specify the output yaml folder"), llvm::cl::value_desc("<dir_path>"));
llvm::cl::opt<string> cla_outputModuleMapsFolder("output-modulemaps", llvm::cl::desc("Specify the fodler where modulemap files of all parsed modules will be dumped"), llvm::cl::value_desc("<dir_path>"));
llvm::cl::opt<string> cla_outputBinFile("output-bin", llvm::cl::desc("Specify the output binary metadata file"), llvm::cl::value_desc("<file_path>"));
llvm::cl::opt<string> cla_outputDtsFolder("output-typescript", llvm::cl::desc("Specify the output .d.ts folder"), llvm::cl::value_desc("<dir_path>"));
llvm::cl::opt<string> cla_docSetFile("docset-path", llvm::cl::desc("Specify the path to the iOS SDK docset package"), llvm::cl::value_desc("<file_path>"));
llvm::cl::opt<string> cla_blackListModuleRegexesFile("blacklist-modules-file", llvm::cl::desc("Specify the metadata entries blacklist file containing regexes of module names on each line"), llvm::cl::value_desc("file_path"));
llvm::cl::opt<string> cla_whiteListModuleRegexesFile("whitelist-modules-file", llvm::cl::desc("Specify the metadata entries whitelist file containing regexes of module names on each line"), llvm::cl::value_desc("file_path"));
llvm::cl::opt<bool>   cla_applyManualDtsChanges("apply-manual-dts-changes", llvm::cl::desc("Specify whether to disable manual adjustments to generated .d.ts files for specific erroneous cases in the iOS SDK"), llvm::cl::init(true));
llvm::cl::opt<string> cla_clangArgumentsDelimiter(llvm::cl::Positional, llvm::cl::desc("Xclang"), llvm::cl::init("-"));
llvm::cl::list<string> cla_clangArguments(llvm::cl::ConsumeAfter, llvm::cl::desc("<clang arguments>..."));

// Swift support
llvm::cl::list<string> cla_swiftSymbolGraphDir(
    "swift-symbolgraph-dir",
    llvm::cl::desc(
        "Directory containing Swift .symbolgraph files to import (repeatable)"),
    llvm::cl::value_desc("<dir_path>"));
llvm::cl::list<string> cla_swiftReexports(
    "swift-reexport",
    llvm::cl::desc("<Detail>=<Module>: module Detail is an implementation "
                   "detail Module re-exports; generated code names it through "
                   "Module (repeatable; SwiftUICore=SwiftUI is implied)"),
    llvm::cl::value_desc("<detail>=<module>"));
llvm::cl::opt<string> cla_swiftUnit(
    "swift-unit",
    llvm::cl::desc("Generate every imported Swift module as one unit with this "
                   "name: one thunk file, cross-module types and extensions"),
    llvm::cl::value_desc("<name>"));
llvm::cl::opt<bool>   cla_skipObjC("skip-objc", llvm::cl::desc("Skip Objective-C parsing and only run Swift symbolgraph import"), llvm::cl::init(false));
llvm::cl::opt<string> cla_swiftIROutputDir(
    "swift-ir-output",
    llvm::cl::desc("Directory to write the Swift IR (<Module>.swift-ir.json) "
                   "for each imported module"),
    llvm::cl::value_desc("<dir_path>"));
llvm::cl::opt<string> cla_swiftDeploymentTarget(
    "swift-deployment-target",
    llvm::cl::desc("Deployment target (e.g. 15.0) for Swift availability "
                   "decisions; defaults to the minimum version recorded in "
                   "the symbol graphs"),
    llvm::cl::value_desc("<version>"));
llvm::cl::opt<bool> cla_swiftVerify(
    "swift-verify",
    llvm::cl::desc("Type-check the Swift-generated surface with the Swift "
                   "compiler and demote every declaration it rejects"),
    llvm::cl::init(false));
llvm::cl::opt<string> cla_swiftCompiler(
    "swift-compiler",
    llvm::cl::desc("Swift compiler command for --swift-verify"),
    llvm::cl::init("xcrun swiftc"));
llvm::cl::opt<string> cla_swiftSDK(
    "swift-sdk", llvm::cl::desc("SDK path for --swift-verify"),
    llvm::cl::value_desc("<path>"));
llvm::cl::opt<string> cla_swiftTarget(
    "swift-target", llvm::cl::desc("Target triple for --swift-verify"),
    llvm::cl::value_desc("<triple>"));
llvm::cl::list<string> cla_swiftSearchPaths(
    "swift-search-path",
    llvm::cl::desc("Module search path (-I) for --swift-verify"),
    llvm::cl::value_desc("<dir_path>"));
llvm::cl::list<string> cla_swiftFrameworkSearchPaths(
    "swift-framework-search-path",
    llvm::cl::desc("Framework search path (-F) for --swift-verify"),
    llvm::cl::value_desc("<dir_path>"));
llvm::cl::opt<string> cla_swiftWorkDir(
    "swift-work-dir",
    llvm::cl::desc("Scratch directory for --swift-verify (default: a "
                   "temporary directory)"),
    llvm::cl::value_desc("<dir_path>"));
llvm::cl::opt<string> cla_swiftThunkOutputDir(
    "swift-thunk-output",
    llvm::cl::desc("Directory to write Swift interop thunks "
                   "(<Module>+NativeScript.swift)"),
    llvm::cl::value_desc("<dir_path>"));
llvm::cl::opt<string> cla_swiftCoverageOutputDir(
    "swift-coverage-output",
    llvm::cl::desc("Directory to write Swift coverage reports "
                   "(<Module>.coverage.json)"),
    llvm::cl::value_desc("<dir_path>"));
llvm::cl::opt<string> cla_swiftProbeOutputDir(
    "swift-probe-output",
    llvm::cl::desc("Directory to write compiler-validation probes "
                   "(<Module>.probe.swift and <Module>.probe-map.json)"),
    llvm::cl::value_desc("<dir_path>"));

class MetaGenerationConsumer : public clang::ASTConsumer {
public:
    explicit MetaGenerationConsumer(clang::SourceManager& sourceManager, clang::HeaderSearch& headerSearch, Meta::ModulesBlacklist& modulesBlacklist)
        : _headerSearch(headerSearch)
        , _visitor(sourceManager, _headerSearch, cla_verbose, modulesBlacklist)
    {
    }

    virtual void HandleTranslationUnit(clang::ASTContext& Context) override
    {
        Context.getDiagnostics().Reset();
        llvm::SmallVector<clang::Module*, 64> modules;
        _headerSearch.collectAllModules(modules);
        std::list<Meta::Meta*>& metaContainer = _visitor.generateMetadata(Context.getTranslationUnitDecl());

        // Filters
        Meta::HandleExceptionalMetasFilter().filter(metaContainer);
        Meta::MergeCategoriesFilter().filter(metaContainer);
        Meta::RemoveDuplicateMembersFilter().filter(metaContainer);
        Meta::HandleMethodsAndPropertiesWithSameNameFilter(_visitor.getMetaFactory()).filter(metaContainer);
        Meta::ResolveGlobalNamesCollisionsFilter filter = Meta::ResolveGlobalNamesCollisionsFilter();
        filter.filter(metaContainer);
        std::unique_ptr<std::pair<Meta::ResolveGlobalNamesCollisionsFilter::MetasByModules, Meta::ResolveGlobalNamesCollisionsFilter::InterfacesByName> > result = filter.getResult();
        Meta::ResolveGlobalNamesCollisionsFilter::MetasByModules& metasByModules = result->first;
        Meta::ResolveGlobalNamesCollisionsFilter::InterfacesByName& interfacesByName = result->second;
        _visitor.getMetaFactory().getTypeFactory().resolveCachedBridgedInterfaceTypes(interfacesByName);

        // Log statistic for parsed Meta objects
        std::cout << "Result: " << metaContainer.size() << " declarations from " << metasByModules.size() << " top level modules" << std::endl;

        // Dump module maps
        if (!cla_outputModuleMapsFolder.empty()) {
            llvm::sys::fs::create_directories(cla_outputModuleMapsFolder);
            for (clang::Module*& module : modules) {
                std::string filePath = std::string(cla_outputModuleMapsFolder) + std::string("/") + module->getFullModuleName() + ".modulemap";
                std::error_code error;
                llvm::raw_fd_ostream file(filePath, error, llvm::sys::fs::OF_Text);
                if (error) {
                    std::cout << error.message();
                    continue;
                }
                module->print(file);
                file.close();
            }
        }

        // Serialize Meta objects to Yaml
        if (!cla_outputYamlFolder.empty()) {
            if (!llvm::sys::fs::exists(cla_outputYamlFolder)) {
                DEBUG_WITH_TYPE("yaml", llvm::dbgs() << "Creating YAML output directory: " << cla_outputYamlFolder << "\n");
                llvm::sys::fs::create_directories(cla_outputYamlFolder);
            }

            for (std::pair<clang::Module*, std::vector<Meta::Meta*> >& modulePair : metasByModules) {
                std::string yamlFileName = modulePair.first->getFullModuleName() + ".yaml";
                DEBUG_WITH_TYPE("yaml", llvm::dbgs() << "Generating: " << yamlFileName << "\n");
                Yaml::YamlSerializer::serialize<std::pair<clang::Module*, std::vector<Meta::Meta*> > >(cla_outputYamlFolder + "/" + yamlFileName, modulePair);
            }
        }

        // Serialize Meta objects to binary metadata
        if (!cla_outputBinFile.empty()) {
            binary::MetaFile file(metaContainer.size() / 10); // Average number of hash collisions: 10 per bucket
            binary::BinarySerializer serializer(&file);
            serializer.serializeContainer(metasByModules);
            file.save(cla_outputBinFile);
        }

    // Generate TypeScript definitions (Objective-C)
        if (!cla_outputDtsFolder.empty()) {
            llvm::sys::fs::create_directories(cla_outputDtsFolder);
            std::string docSetPath = cla_docSetFile.empty() ? "" : cla_docSetFile.getValue();
            for (std::pair<clang::Module*, std::vector<Meta::Meta*> >& modulePair : metasByModules) {
                TypeScript::DefinitionWriter definitionWriter(modulePair, _visitor.getMetaFactory().getTypeFactory(), docSetPath);

                llvm::SmallString<128> path;
                llvm::sys::path::append(path, cla_outputDtsFolder, "objc!" + modulePair.first->getFullModuleName() + ".d.ts");
                std::error_code error;
                llvm::raw_fd_ostream file(path.str(), error, llvm::sys::fs::OF_Text);
                if (error) {
                    std::cout << error.message();
                    return;
                }

                file << definitionWriter.write();
                file.close();
            }
        }
    }

private:
    clang::HeaderSearch& _headerSearch;
    Meta::DeclarationConverterVisitor _visitor;
};

class MetaGenerationFrontendAction : public clang::ASTFrontendAction {
public:
    MetaGenerationFrontendAction(Meta::ModulesBlacklist& modulesBlacklist)
        : _modulesBlacklist(modulesBlacklist)
    {
    }

    virtual std::unique_ptr<clang::ASTConsumer> CreateASTConsumer(clang::CompilerInstance& Compiler, llvm::StringRef InFile) override
    {
        // Since in 4.0.1 'includeNotFound' errors are ignored for some reason
        // (even though the 'suppressIncludeNotFound' setting is false)
        // here we set this explicitly in order to keep the same behavior
        Compiler.getPreprocessor().SetSuppressIncludeNotFoundError(!cla_strictIncludes);

        return std::unique_ptr<clang::ASTConsumer>(new MetaGenerationConsumer(Compiler.getASTContext().getSourceManager(), Compiler.getPreprocessor().getHeaderSearchInfo(), _modulesBlacklist));
    }

private:
    Meta::ModulesBlacklist& _modulesBlacklist;
};

std::string replaceString(std::string subject, const std::string& search, const std::string& replace)
{
    size_t pos = 0;
    while ((pos = subject.find(search, pos)) != std::string::npos) {
        subject.replace(pos, search.length(), replace);
        pos += replace.length();
    }
    return subject;
}

static void dumpArgs(std::ostream& os, int argc, const char **argv) {
    os << "Metadata Generator Arguments: " << std::endl;
    for (int i = 0; i < argc; ++i) {
        std::string arg = *(argv + i);
        os << arg << " ";
    }
    os << std::endl;
}

int main(int argc, const char** argv)
{
    try {
        std::clock_t begin = clock();

        llvm::cl::ParseCommandLineOptions(argc, argv);
        assert(cla_clangArgumentsDelimiter.getValue() == "Xclang");

        // Log Metadata Genrator Arguments
        dumpArgs(std::cout, argc, argv);
        dumpArgs(std::cerr, argc, argv);

        TypeScript::DefinitionWriter::applyManualChanges = cla_applyManualDtsChanges;

        if (!cla_skipObjC) {
            std::vector<std::string> clangArgs{
                "-v",
                "-x", "objective-c",
                "-fno-objc-arc", "-fmodule-maps", "-ferror-limit=0",
                "-Wno-unknown-pragmas", "-Wno-ignored-attributes", "-Wno-nullability-completeness", "-Wno-expansion-to-defined",
                "-D__NATIVESCRIPT_METADATA_GENERATOR=1"
            };

            // merge with hardcoded clang arguments
            clangArgs.insert(clangArgs.end(), cla_clangArguments.begin(), cla_clangArguments.end());

            // Log Clang Arguments
            std::cout << "Clang Arguments: \n";
            for (const std::string& arg : clangArgs) {
                std::cout << "\"" << arg << "\"," << " ";
            }
            std::cout << std::endl;

            std::string isysroot;
            std::vector<string>::const_iterator it = std::find(clangArgs.begin(), clangArgs.end(), "-isysroot");
            if (it != clangArgs.end() && ++it != clangArgs.end()) {
                isysroot = *it;
            }

            std::vector<std::string> includePaths;
            std::string umbrellaContent = CreateUmbrellaHeader(clangArgs, includePaths);

            if (!cla_inputUmbrellaHeaderFile.empty()) {
                std::ifstream fs(cla_inputUmbrellaHeaderFile);
                umbrellaContent = std::string((std::istreambuf_iterator<char>(fs)), std::istreambuf_iterator<char>());
            }

            clangArgs.insert(clangArgs.end(), includePaths.begin(), includePaths.end());

            // Save the umbrella file
            if (!cla_outputUmbrellaHeaderFile.empty()) {
                std::error_code errorCode;
                llvm::raw_fd_ostream umbrellaFileStream(cla_outputUmbrellaHeaderFile, errorCode, llvm::sys::fs::OpenFlags::OF_None);
                if (!errorCode) {
                    umbrellaFileStream << umbrellaContent;
                    umbrellaFileStream.close();
                }
            }
            // generate metadata for the intermediate sdk header
            Meta::ModulesBlacklist modulesBlacklist(cla_whiteListModuleRegexesFile, cla_blackListModuleRegexesFile);
            clang::tooling::runToolOnCodeWithArgs(std::unique_ptr<MetaGenerationFrontendAction>(new MetaGenerationFrontendAction(/*r*/modulesBlacklist)), umbrellaContent, clangArgs, "umbrella.h", "objc-metadata-generator");
        }

        // Swift: read symbol graphs and emit TS
        bool swiftFailed = false;
        if (!cla_swiftSymbolGraphDir.empty()) {
          Swift::ModuleSet swiftModules = Swift::loadSymbolGraphDirectories(
              std::vector<std::string>(cla_swiftSymbolGraphDir.begin(),
                                       cla_swiftSymbolGraphDir.end()));
          for (const auto& diagnostic : swiftModules.diagnostics) {
            std::cerr << (diagnostic.severity == Swift::Severity::Error
                              ? "error"
                              : "warning")
                      << ": swift [" << diagnostic.code << "] "
                      << diagnostic.file;
            if (!diagnostic.symbolId.empty()) {
              std::cerr << " (" << diagnostic.symbolId << ")";
            }
            std::cerr << ": " << diagnostic.message << std::endl;
          }
          swiftFailed = swiftModules.hasErrors();

          auto writeFile = [](llvm::StringRef folder, llvm::StringRef fileName,
                              const std::string& content) {
            llvm::sys::fs::create_directories(folder);
            llvm::SmallString<128> path;
            llvm::sys::path::append(path, folder, fileName);
            std::error_code error;
            llvm::raw_fd_ostream file(path.str(), error,
                                      llvm::sys::fs::OF_Text);
            if (error) {
              std::cerr << "error: " << path.str().str() << ": "
                        << error.message() << std::endl;
              return false;
            }
            file << content;
            return true;
          };

          if (!cla_swiftDeploymentTarget.empty()) {
            Swift::Version target;
            llvm::StringRef rest = cla_swiftDeploymentTarget.getValue();
            auto major = rest.split('.');
            auto minor = major.second.split('.');
            if (major.first.getAsInteger(10, target.major) ||
                (!minor.first.empty() &&
                 minor.first.getAsInteger(10, target.minor)) ||
                (!minor.second.empty() &&
                 minor.second.getAsInteger(10, target.patch))) {
              std::cerr << "error: invalid --swift-deployment-target '"
                        << cla_swiftDeploymentTarget << "'" << std::endl;
              return 1;
            }
            for (auto& entry : swiftModules.modules) {
              entry.second.platform.minimumVersion = target;
            }
          }
          if (!cla_swiftUnit.empty() && !swiftFailed) {
            std::map<std::string, std::string> reexports = {
                {"SwiftUICore", "SwiftUI"}};
            for (const auto& entry : cla_swiftReexports) {
              auto parts = llvm::StringRef(entry).split('=');
              reexports[parts.first.str()] = parts.second.str();
            }
            for (auto it = reexports.begin(); it != reexports.end();) {
              it = swiftModules.modules.count(it->second) ? std::next(it)
                                                          : reexports.erase(it);
            }
            Swift::Module unit =
                Swift::mergeUnit(swiftModules, cla_swiftUnit, reexports);
            swiftModules.modules.emplace(unit.name, std::move(unit));
          }

          for (auto& entry : swiftModules.modules) {
            Swift::instantiateGenerics(entry.second);
          }
          for (const auto& entry : swiftModules.modules) {
            const Swift::Module& module = entry.second;
            if (!cla_swiftIROutputDir.empty()) {
              swiftFailed |= !writeFile(cla_swiftIROutputDir,
                                        module.name + ".swift-ir.json",
                                        Swift::dumpModuleJSON(module));
            }
            if (cla_outputDtsFolder.empty() &&
                cla_swiftCoverageOutputDir.empty() &&
                cla_swiftProbeOutputDir.empty() &&
                cla_swiftThunkOutputDir.empty()) {
              continue;
            }
            Swift::Classification classification;
            int compilerRuns = -1;
            if (cla_swiftVerify) {
              Swift::VerifyOptions options;
              options.compiler.clear();
              llvm::SmallVector<llvm::StringRef, 4> words;
              llvm::StringRef(cla_swiftCompiler).split(words, ' ', -1, false);
              for (auto word : words) {
                options.compiler.push_back(word.str());
              }
              options.sdk = cla_swiftSDK;
              options.target = cla_swiftTarget;
              options.searchPaths.assign(cla_swiftSearchPaths.begin(),
                                         cla_swiftSearchPaths.end());
              options.frameworkSearchPaths.assign(
                  cla_swiftFrameworkSearchPaths.begin(),
                  cla_swiftFrameworkSearchPaths.end());
              options.workDirectory = cla_swiftWorkDir;
              if (options.workDirectory.empty()) {
                llvm::SmallString<128> temporary;
                llvm::sys::fs::createUniqueDirectory("ns-swift-verify",
                                                     temporary);
                options.workDirectory = temporary.str().str();
              }
              Swift::VerifyResult verified =
                  Swift::verifyWithCompiler(module, options);
              if (!verified.failure.empty()) {
                std::cerr << "error: swift [verification-failed] "
                          << module.name << ": " << verified.failure
                          << std::endl;
                swiftFailed = true;
                continue;
              }
              for (const auto& rejection : verified.rejections) {
                std::cerr << "warning: swift [compiler-rejected] "
                          << module.name << " (" << rejection.first
                          << "): " << rejection.second << std::endl;
              }
              classification = std::move(verified.classification);
              compilerRuns = verified.compilerRuns;
            } else {
              classification = Swift::classify(module);
            }
            if (!cla_outputDtsFolder.empty()) {
              for (const auto& name : module.swiftModules()) {
                TypeScript::SwiftDefinitionWriter swiftWriter(
                    module, classification, name);
                swiftFailed |=
                    !writeFile(cla_outputDtsFolder, "swift!" + name + ".d.ts",
                               swiftWriter.write());
              }
            }
            if (!cla_swiftCoverageOutputDir.empty()) {
              swiftFailed |= !writeFile(
                  cla_swiftCoverageOutputDir, module.name + ".coverage.json",
                  Swift::coverageJSON(module, classification, compilerRuns));
            }
            if (!cla_swiftThunkOutputDir.empty()) {
              Swift::ThunkSource thunks =
                  Swift::emitThunks(module, classification);
              swiftFailed |= !writeFile(cla_swiftThunkOutputDir,
                                        module.name + "+NativeScript.swift",
                                        thunks.source);
            }
            if (!cla_swiftProbeOutputDir.empty()) {
              Swift::ProbeSource probes =
                  Swift::emitProbes(module, classification);
              std::string map;
              llvm::raw_string_ostream mapStream(map);
              llvm::json::OStream mapJSON(mapStream, 2);
              mapJSON.object([&] {
                for (const auto& line : probes.lineToSymbol) {
                  mapJSON.attribute(std::to_string(line.first), line.second);
                }
              });
              mapStream << "\n";
              mapStream.flush();
              swiftFailed |=
                  !writeFile(cla_swiftProbeOutputDir,
                             module.name + ".probe.swift", probes.source);
              swiftFailed |= !writeFile(cla_swiftProbeOutputDir,
                                        module.name + ".probe-map.json", map);
            }
          }
        }

        std::clock_t end = clock();
        double elapsed_secs = double(end - begin) / CLOCKS_PER_SEC;
        std::cout << "Done! Running time: " << elapsed_secs << " sec " << std::endl;

        return swiftFailed ? 1 : 0;
    } catch (const std::exception& e) {
        std::cerr << "error: " << e.what() << std::endl;
        return 1;
    }
}
