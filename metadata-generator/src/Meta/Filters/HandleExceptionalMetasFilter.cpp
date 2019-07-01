#include "HandleExceptionalMetasFilter.h"
#include <Meta/TypeFactory.h>

namespace Meta {

// Exposes a method [UIResponder copy:] which conflicts with [NSObject copy] so we remove it
static void handleUIResponderStandardEditActions(std::list<Meta*>& container)
{
    for (Meta* meta : container) {
        bool found = false;

        if (meta->is(MetaType::Category)) {
            InterfaceMeta* extendedInterface = meta->as<CategoryMeta>().extendedInterface;
            if (meta->name == "UIResponderStandardEditActions" && meta->module->getFullModuleName() == "UIKit.UIResponder" && extendedInterface->name == "NSObject") {
                found = true;
            }
        } else if (meta->is(MetaType::Protocol)) {
            if (meta->name == "UIResponderStandardEditActions" && meta->module->getFullModuleName() == "UIKit.UIResponder") {
                found = true;
            }
        }

        if (found) {
            auto& methods = meta->as<BaseClassMeta>().instanceMethods;
            methods.erase(std::remove_if(methods.begin(), methods.end(), [](const MethodMeta* m) {
                return m->jsName == "copy";
            }),
                methods.end());

            break;
        }
    }
}

// Change the return type of [NSNull null] to instancetype
// TODO: remove the special handling of [NSNull null] from metadata generator and handle it in the runtime
static void handleNSNullType(std::list<Meta*>& container)
{
    for (Meta* meta : container) {
        if (meta->is(MetaType::Interface) && meta->name == "NSNull" && meta->module->getFullModuleName() == "Foundation.NSNull") {
            InterfaceMeta& nsNullMeta = meta->as<InterfaceMeta>();
            for (MethodMeta* method : nsNullMeta.staticMethods) {
                if (method->getSelector() == "null") {
                    method->signature[0] = TypeFactory::getInstancetype().get();
                    return;
                }
            }
        }
    }
}

void HandleExceptionalMetasFilter::filter(std::list<Meta*>& container)
{
    handleUIResponderStandardEditActions(container);
    handleNSNullType(container);
}
}
