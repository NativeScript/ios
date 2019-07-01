#include "RemoveDuplicateMembersFilter.h"
#include "Meta/Utils.h"

namespace Meta {
static bool areMethodsEqual(MethodMeta& method1, MethodMeta& method2)
{
    return (method1.getSelector() == method2.getSelector()) && Utils::areTypesEqual(method1.signature, method2.signature);
}

static bool arePropertiesEqual(PropertyMeta& prop1, PropertyMeta& prop2)
{
    if (prop1.name == prop2.name) {
        if ((bool)prop1.getter == (bool)prop2.getter && (bool)prop1.setter == (bool)prop2.setter) {
            if (prop1.getter)
                return areMethodsEqual(*prop1.getter, *prop2.getter);
            else
                return areMethodsEqual(*prop1.setter, *prop2.setter);
        }
    }
    return false;
}

static void removeDuplicateMethods(std::vector<MethodMeta*>& from, std::vector<MethodMeta*>& duplicates)
{
    for (MethodMeta* dupMethod : duplicates) {
        from.erase(std::remove_if(from.begin(),
                       from.end(),
                       [&](MethodMeta* method) {
                           return areMethodsEqual(*method, *dupMethod);
                       }),
            from.end());
    }
}

static void removeDuplicateProperties(std::vector<PropertyMeta*>& from, std::vector<PropertyMeta*>& duplicates)
{
    for (PropertyMeta* dupProperty : duplicates) {
        from.erase(std::remove_if(from.begin(),
                       from.end(),
                       [&](PropertyMeta* property) {
                           return arePropertiesEqual(*property, *dupProperty);
                       }),
            from.end());
    }
}

static void removeDuplicateMembersFromChild(BaseClassMeta* child, BaseClassMeta* parent)
{
    removeDuplicateMethods(child->staticMethods, parent->staticMethods);
    removeDuplicateMethods(child->instanceMethods, parent->instanceMethods);
    removeDuplicateProperties(child->instanceProperties, parent->instanceProperties);
    removeDuplicateProperties(child->staticProperties, parent->staticProperties);
}

static void processBaseClassAndHierarchyOf(BaseClassMeta* child, BaseClassMeta* parent)
{
    if (child != parent) {
        removeDuplicateMembersFromChild(child, parent);
    }
    for (ProtocolMeta* protocol : parent->protocols) {
        processBaseClassAndHierarchyOf(child, protocol);
    }
    if (parent->is(MetaType::Interface)) {
        InterfaceMeta* parentInterface = &parent->as<InterfaceMeta>();
        if (parentInterface->base != nullptr) {
            processBaseClassAndHierarchyOf(child, parentInterface->base);
        }
    }
}

void RemoveDuplicateMembersFilter::filter(std::list<Meta*>& container)
{
    for (Meta* meta : container) {
        if (meta->is(MetaType::Interface) || meta->is(MetaType::Protocol)) {
            BaseClassMeta* baseClass = &meta->as<BaseClassMeta>();
            processBaseClassAndHierarchyOf(baseClass, baseClass);
        }
    }
}
}