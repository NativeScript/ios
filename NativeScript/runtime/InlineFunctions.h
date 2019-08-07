#ifndef InlineFunctions_h
#define InlineFunctions_h

#include "Common.h"

namespace tns {

class InlineFunctions {
public:
    static void Init(v8::Isolate* isolate);
    static std::vector<std::string> GlobalFunctions;
};

}

#endif /* InlineFunctions_h */
