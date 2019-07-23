#include "NativeScript.h"
#include "Runtime/Runtime.h"

namespace tns {

void NativeScript::Start(void* metadataPtr, std::string baseDir) {
    tns::Runtime::InitializeMetadata(metadataPtr);
    tns::Runtime* runtime = new tns::Runtime();
    runtime->InitAndRunMainScript(baseDir);
}

}
