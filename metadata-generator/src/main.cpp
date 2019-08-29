#include "Binary/binarySerializer.h"
#include "HeadersParser/Parser.h"
#include "Meta/DeclarationConverterVisitor.h"
#include "Meta/Filters/HandleExceptionalMetasFilter.h"
#include "Meta/Filters/HandleMethodsAndPropertiesWithSameNameFilter.h"
#include "Meta/Filters/MergeCategoriesFilter.h"
#include "Meta/Filters/RemoveDuplicateMembersFilter.h"
#include "Meta/Filters/ResolveGlobalNamesCollisionsFilter.h"
#include "TypeScript/DefinitionWriter.h"
#include "TypeScript/DocSetManager.h"
#include "Yaml/YamlSerializer.h"
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Tooling/Tooling.h>
#include <fstream>
#include <llvm/Support/Debug.h>
#include <llvm/Support/Path.h>
#include <pwd.h>
#include <sstream>

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
llvm::cl::opt<string> cla_clangArgumentsDelimiter(llvm::cl::Positional, llvm::cl::desc("Xclang"), llvm::cl::init("-"));
llvm::cl::list<string> cla_clangArguments(llvm::cl::ConsumeAfter, llvm::cl::desc("<clang arguments>..."));

class MetaGenerationConsumer : public clang::ASTConsumer {
public:
    explicit MetaGenerationConsumer(clang::SourceManager& sourceManager, clang::HeaderSearch& headerSearch)
        : _headerSearch(headerSearch)
        , _visitor(sourceManager, _headerSearch, cla_verbose)
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
                llvm::raw_fd_ostream file(filePath, error, llvm::sys::fs::F_Text);
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
            binary::MetaFile file(metasByModules.size());
            binary::BinarySerializer serializer(&file);
            serializer.serializeContainer(metasByModules);
            file.save(cla_outputBinFile);
        }

        // Generate TypeScript definitions
        if (!cla_outputDtsFolder.empty()) {
            llvm::sys::fs::create_directories(cla_outputDtsFolder);
            std::string docSetPath = cla_docSetFile.empty() ? "" : cla_docSetFile.getValue();
            for (std::pair<clang::Module*, std::vector<Meta::Meta*> >& modulePair : metasByModules) {
                TypeScript::DefinitionWriter definitionWriter(modulePair, _visitor.getMetaFactory().getTypeFactory(), docSetPath);

                llvm::SmallString<128> path;
                llvm::sys::path::append(path, cla_outputDtsFolder, "objc!" + modulePair.first->getFullModuleName() + ".d.ts");
                std::error_code error;
                llvm::raw_fd_ostream file(path.str(), error, llvm::sys::fs::F_Text);
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
    MetaGenerationFrontendAction()
    {
    }

    virtual std::unique_ptr<clang::ASTConsumer> CreateASTConsumer(clang::CompilerInstance& Compiler, llvm::StringRef InFile) override
    {
        // Since in 4.0.1 'includeNotFound' errors are ignored for some reason
        // (even though the 'suppressIncludeNotFound' setting is false)
        // here we set this explicitly in order to keep the same behavior
        Compiler.getPreprocessor().SetSuppressIncludeNotFoundError(!cla_strictIncludes);
        
        return std::unique_ptr<clang::ASTConsumer>(new MetaGenerationConsumer(Compiler.getASTContext().getSourceManager(), Compiler.getPreprocessor().getHeaderSearchInfo()));
    }
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

int main(int argc, const char** argv)
{
    std::clock_t begin = clock();

    llvm::cl::ParseCommandLineOptions(argc, argv);
    assert(cla_clangArgumentsDelimiter.getValue() == "Xclang");

    // Log Metadata Genrator Arguments
    std::cout << "Metadata Generator Arguments: " << std::endl;
    TypeScript::DefinitionWriter::applyManualChanges = true;
    for (int i = 0; i < argc; ++i) {
        std::string arg = *(argv + i);
        std::cout << "\"" << arg << "\", ";
        if (arg == "--no-apply-manual-changes") {
            TypeScript::DefinitionWriter::applyManualChanges = false;
        }
    }
    std::cout << std::endl;

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
        std::cout << "\"" << arg << "\","
                  << " ";
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
        umbrellaContent = std::string((std::istreambuf_iterator<char>(fs)),
                                      std::istreambuf_iterator<char>());
    }
    
    clangArgs.insert(clangArgs.end(), includePaths.begin(), includePaths.end());
    
    // Save the umbrella file
    if (!cla_outputUmbrellaHeaderFile.empty()) {
        std::error_code errorCode;
        llvm::raw_fd_ostream umbrellaFileStream(cla_outputUmbrellaHeaderFile, errorCode, llvm::sys::fs::OpenFlags::F_None);
        if (!errorCode) {
            umbrellaFileStream << umbrellaContent;
            umbrellaFileStream.close();
        }
    }

    // generate metadata for the intermediate sdk header
    clang::tooling::runToolOnCodeWithArgs(new MetaGenerationFrontendAction(), umbrellaContent, clangArgs, "umbrella.h", "objc-metadata-generator");
    
    std::clock_t end = clock();
    double elapsed_secs = double(end - begin) / CLOCKS_PER_SEC;
    std::cout << "Done! Running time: " << elapsed_secs << " sec " << std::endl;

    return 0;
}
