#pragma once
#include "Meta/MetaEntities.h"

namespace Meta {
class RemoveDuplicateMembersFilter {
public:
    void filter(std::list<Meta*>& container);
};
}