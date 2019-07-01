#pragma once
#include "Meta/MetaEntities.h"

namespace Meta {
class HandleExceptionalMetasFilter {
public:
    void filter(std::list<Meta*>& container);
};
}