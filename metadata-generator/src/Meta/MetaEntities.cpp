#include "MetaEntities.h"


Meta::Version Meta::Version::Unknown = UNKNOWN_VERSION;

static void visitBaseClass(Meta::MetaVisitor* visitor, Meta::BaseClassMeta* baseClass)
{
    for (Meta::MethodMeta* method : baseClass->staticMethods) {
        method->visit(visitor);
    }

    for (Meta::MethodMeta* method : baseClass->instanceMethods) {
        method->visit(visitor);
    }

    for (Meta::PropertyMeta* property : baseClass->instanceProperties) {
        property->visit(visitor);
    }

    for (Meta::PropertyMeta* property : baseClass->staticProperties) {
        property->visit(visitor);
    }
}

void Meta::MethodMeta::visit(MetaVisitor* visitor)
{
    visitor->visit(this);
}

void Meta::PropertyMeta::visit(MetaVisitor* visitor)
{
    visitor->visit(this);
}

void Meta::EnumConstantMeta::visit(MetaVisitor* visitor)
{
    visitor->visit(this);
}

void Meta::CategoryMeta::visit(MetaVisitor* visitor)
{
    visitor->visit(this);
    visitBaseClass(visitor, this);
}

void Meta::InterfaceMeta::visit(MetaVisitor* visitor)
{
    visitor->visit(this);
    visitBaseClass(visitor, this);
}

void Meta::ProtocolMeta::visit(MetaVisitor* visitor)
{
    visitor->visit(this);
    visitBaseClass(visitor, this);
}

void Meta::StructMeta::visit(MetaVisitor* visitor)
{
    visitor->visit(this);
}

void Meta::UnionMeta::visit(MetaVisitor* visitor)
{
    visitor->visit(this);
}

void Meta::FunctionMeta::visit(MetaVisitor* visitor)
{
    visitor->visit(this);
}

void Meta::EnumMeta::visit(MetaVisitor* visitor)
{
    visitor->visit(this);
}

void Meta::VarMeta::visit(MetaVisitor* visitor)
{
    visitor->visit(this);
}
