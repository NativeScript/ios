#ifndef utils_h
#define utils_h

#include "include/v8-inspector.h"
#include <vector>

namespace v8_inspector {
    std::string ToStdString(const v8_inspector::StringView& value);
    std::vector<uint16_t> ToVector(const std::string& value);
}

#endif /* utils_h */
