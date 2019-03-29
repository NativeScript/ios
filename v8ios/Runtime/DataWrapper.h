#ifndef Common_h
#define Common_h

#include "Metadata.h"

namespace tns {

struct DataWrapper {
public:
    DataWrapper(id data): data_(data), meta_(nullptr) {}
    DataWrapper(id data, const Meta* meta): data_(data), meta_(meta) {}
    id data_;
    const Meta* meta_;
};

}

#endif /* Common_h */
