#pragma once

#include "Meta/MetaEntities.h"

uint8_t convertVersion(Meta::Version version);
template <typename T>
bool compareMetasByJsName(T* meta1, T* meta2)
{
    return meta1->jsName < meta2->jsName;
}