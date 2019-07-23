#ifndef NativeScript_h
#define NativeScript_h

#include <string>

namespace tns {

class NativeScript {
public:
    static void Start(void* metadataPtr, std::string baseDir);
};

}

#endif /* NativeScript_h */
