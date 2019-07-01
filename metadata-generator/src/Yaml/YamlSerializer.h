#pragma once

#include "MetaYamlTraits.h"
#include <llvm/Support/FileSystem.h>
#include <string>

namespace Yaml {
class YamlSerializer {
public:
    template <class T>
    static void serialize(std::string outputFilePath, T& object)
    {
        std::error_code errorCode;
        llvm::raw_fd_ostream fileStream(outputFilePath, errorCode, llvm::sys::fs::OpenFlags::F_None);
        if (errorCode)
            throw std::runtime_error(std::string("Unable to open file ") + outputFilePath + ".");
        llvm::yaml::Output output(fileStream);
        output << object;
        fileStream.close();
    }
};
}
