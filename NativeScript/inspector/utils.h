#ifndef utils_h
#define utils_h

#include "include/v8-inspector.h"
#include <vector>

namespace v8_inspector {
    std::string GetMIMEType(std::string filePath);
    std::string ToStdString(const v8_inspector::StringView& value);
}

#endif /* utils_h */
