//
// Created by Ivan Buhov on 9/5/15.
//
#pragma once
#include "Meta/MetaEntities.h"

namespace Meta {
class MergeCategoriesFilter {
public:
    void filter(std::list<Meta*>& container);
};
}