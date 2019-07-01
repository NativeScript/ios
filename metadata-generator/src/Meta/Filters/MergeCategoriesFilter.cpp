//
// Created by Ivan Buhov on 9/5/15.
//

#include "MergeCategoriesFilter.h"

namespace Meta {
static bool isCategory(Meta* meta)
{
    return meta->is(MetaType::Category);
}

// We shouldn't define more than 1 property with the same name
// Whenever an extension redefines a property from the interface
// We should choose the one which will eventually win.
// Basically, the criteria is to choose the one that has not been deprecated or is newer
template<class T>
void addWithOverwrite(std::vector<T*>& v, T* newItem) {
    auto equalNames = [&newItem](T* o) { return o->name == newItem->name; };

    auto duplicateIt = std::find_if(v.begin(), v.end(), equalNames);

    if (duplicateIt != v.end()) {
        T* oldItem = *duplicateIt;

        bool shouldOverwrite =
            newItem->deprecatedIn.isGreaterThanOrUnknown(oldItem->deprecatedIn) &&
            newItem->obsoletedIn.isGreaterThanOrUnknown(oldItem->obsoletedIn);
        
        if (shouldOverwrite) {
            *duplicateIt = newItem;
        }

    } else {
        v.push_back(newItem);
    }
}
    
void MergeCategoriesFilter::filter(std::list<Meta*>& container)
{
    int mergedCategories = 0;
    
    for (Meta* meta : container) {
        if (meta->is(MetaType::Category)) {
            CategoryMeta& category = meta->as<CategoryMeta>();
            assert(category.extendedInterface != nullptr);
            InterfaceMeta& interface = *category.extendedInterface;

            for (auto& method : category.instanceMethods) {
                interface.instanceMethods.push_back(method);
            }

            for (auto& method : category.staticMethods) {
                interface.staticMethods.push_back(method);
            }

            for (auto& property : category.instanceProperties) {
                addWithOverwrite(interface.instanceProperties, property);
            }

            for (auto& property : category.staticProperties) {
                addWithOverwrite(interface.staticProperties, property);
            }

            for (auto& protocol : category.protocols) {
                interface.protocols.push_back(protocol);
            }

            mergedCategories++;
        }
    }

    container.remove_if(isCategory);
    std::cout << "Merged " << mergedCategories << " categories." << std::endl;
}
}
