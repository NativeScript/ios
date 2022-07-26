#include "DefinitionWriter.h"
#include "Meta/Utils.h"
#include "Meta/NameRetrieverVisitor.h"
#include "Utils/StringUtils.h"
#include <algorithm>
#include <clang/AST/DeclObjC.h>
#include <iterator>

namespace TypeScript {
using namespace Meta;

static std::unordered_set<std::string> hiddenMethods = { "retain", "release", "autorelease", "allocWithZone", "zone", "countByEnumeratingWithStateObjectsCount" };

static std::unordered_set<std::string> bannedIdentifiers = { "function", "arguments", "in" };

bool DefinitionWriter::applyManualChanges = false;

static std::string sanitizeParameterName(const std::string& parameterName)
{
    if (bannedIdentifiers.find(parameterName) != bannedIdentifiers.end()) {
        return "_" + parameterName;
    }
    else {
        return parameterName;
    }
}

static std::string getTypeParametersStringOrEmpty(const clang::ObjCInterfaceDecl* interfaceDecl)
{
    std::ostringstream output;
    if (clang::ObjCTypeParamList* typeParameters = interfaceDecl->getTypeParamListAsWritten()) {
        if (typeParameters->size()) {
            output << "<";
            for (unsigned i = 0; i < typeParameters->size(); i++) {
                clang::ObjCTypeParamDecl* typeParam = *(typeParameters->begin() + i);
                output << typeParam->getNameAsString();
                if (i < typeParameters->size() - 1) {
                    output << ", ";
                }
            }
            output << ">";
        }
    }

    return output.str();
}
    
static std::vector<std::string> getTypeParameterNames(const clang::ObjCInterfaceDecl* interfaceDecl)
{
    std::vector<std::string> params;
    if (clang::ObjCTypeParamList* typeParameters = interfaceDecl->getTypeParamListAsWritten()) {
        if (typeParameters->size()) {
            for (unsigned i = 0; i < typeParameters->size(); i++) {
                clang::ObjCTypeParamDecl* typeParam = *(typeParameters->begin() + i);
                params.push_back(typeParam->getNameAsString());
            }
        }
    }
    return params;
}
    
std::string DefinitionWriter::getTypeArgumentsStringOrEmpty(const clang::ObjCObjectType* objectType)
{
    std::ostringstream output;
    llvm::ArrayRef<clang::QualType> typeArgs = objectType->getTypeArgsAsWritten();
    if (!typeArgs.empty()) {
        output << "<";
        for (unsigned i = 0; i < typeArgs.size(); i++) {
            output << tsifyType(*_typeFactory.create(typeArgs[i]));
            if (i < typeArgs.size() - 1) {
                output << ", ";
            }
        }
        output << ">";
    }
    else {
        /* Fill implicit id parameters in similar cases:
         * @interface MyInterface<ObjectType1, ObjectType2>
         * @interface MyDerivedInterface : MyInterface
         */
        if (clang::ObjCTypeParamList* typeParameters = objectType->getInterface()->getTypeParamListAsWritten()) {
            if (typeParameters->size()) {
                output << "<";
                for (unsigned i = 0; i < typeParameters->size(); i++) {
                    output << "NSObject";
                    if (i < typeParameters->size() - 1) {
                        output << ", ";
                    }
                }
                output << ">";
            }
        }
    }

    return output.str();
}

void DefinitionWriter::visit(InterfaceMeta* meta)
{
    CompoundMemberMap<MethodMeta> compoundStaticMethods;
    for (MethodMeta* method : meta->staticMethods) {
        compoundStaticMethods.emplace(method->jsName, std::make_pair(meta, method));
    }

    CompoundMemberMap<MethodMeta> compoundInstanceMethods;
    for (MethodMeta* method : meta->instanceMethods) {
        compoundInstanceMethods.emplace(method->jsName, std::make_pair(meta, method));
    }

    CompoundMemberMap<PropertyMeta> baseClassInstanceProperties;
    CompoundMemberMap<PropertyMeta> ownInstanceProperties;
    for (PropertyMeta* property : meta->instanceProperties) {
        if (ownInstanceProperties.find(property->jsName) == ownInstanceProperties.end()) {
            ownInstanceProperties.emplace(property->jsName, std::make_pair(meta, property));
        }
    }

    CompoundMemberMap<PropertyMeta> baseClassStaticProperties;
    CompoundMemberMap<PropertyMeta> ownStaticProperties;
    for (PropertyMeta* property : meta->staticProperties) {
        if (ownStaticProperties.find(property->jsName) == ownStaticProperties.end()) {
            ownStaticProperties.emplace(property->jsName, std::make_pair(meta, property));
        }
    }

    std::unordered_set<ProtocolMeta*> inheritedProtocols;

    CompoundMemberMap<MethodMeta> inheritedStaticMethods;
    getInheritedMembersRecursive(meta, &inheritedStaticMethods, nullptr, nullptr, nullptr);
    for (auto& methodPair : inheritedStaticMethods) {
        MethodMeta* method = methodPair.second.second;
        if (!method->signature[0]->is(TypeInstancetype)) {
            continue;
        }
        if (compoundStaticMethods.find(method->jsName) != compoundStaticMethods.end()) {
            continue;
        }
        compoundStaticMethods.emplace(methodPair);
    }
    
    std::string metaJsName = meta->jsName;
    std::string parametersString = getTypeParametersStringOrEmpty(clang::cast<clang::ObjCInterfaceDecl>(meta->declaration));
    
    if (DefinitionWriter::applyManualChanges) {
        if (metaJsName == "UIEvent") {
            metaJsName = "_UIEvent";
        } else if (metaJsName == "HMMutableCharacteristicEvent") {
            // We need to add 'extends NSObject in order to inherit NSObject properties. By default it is exported as <TriggerValueType>
            // @interface HMMutableCharacteristicEvent<TriggerValueType : id<NSCopying>> : HMCharacteristicEvent
            parametersString = "<TriggerValueType extends NSObject>";
        }
    }
    
    _buffer << std::endl
            << _docSet.getCommentFor(meta).toString("") << "declare class " << metaJsName << parametersString;
    if (meta->base != nullptr) {
        _buffer << " extends " << localizeReference(*meta->base) << getTypeArgumentsStringOrEmpty(clang::cast<clang::ObjCInterfaceDecl>(meta->declaration)->getSuperClassType());
    }

    CompoundMemberMap<PropertyMeta> protocolInheritedStaticProperties;
    CompoundMemberMap<PropertyMeta> protocolInheritedInstanceProperties;
    std::unordered_set<ProtocolMeta*> protocols;
    if (meta->protocols.size()) {
        _buffer << " implements ";
        for (size_t i = 0; i < meta->protocols.size(); i++) {
            getProtocolMembersRecursive(meta->protocols[i], &compoundStaticMethods, &compoundInstanceMethods, &protocolInheritedStaticProperties, &protocolInheritedInstanceProperties, protocols);
            _buffer << localizeReference(*meta->protocols[i]);
            if (i < meta->protocols.size() - 1) {
                _buffer << ", ";
            }
        }
    }
    _buffer << " {" << std::endl;

    std::unordered_set<ProtocolMeta*> immediateProtocols;
    for (auto protocol : protocols) {
        if (inheritedProtocols.find(protocol) == inheritedProtocols.end()) {
            immediateProtocols.insert(protocol);
        }
    }

    for (auto& methodPair : compoundStaticMethods) {
        if (ownStaticProperties.find(methodPair.first) != ownStaticProperties.end()) {
            continue;
        }

        std::string output = writeMethod(methodPair, meta, immediateProtocols);
        if (output.size()) {
            MethodMeta* method = methodPair.second.second;
            BaseClassMeta* owner = methodPair.second.first;
            _buffer << std::endl
                    << _docSet.getCommentFor(method, owner).toString("\t");
            _buffer << "\tstatic " << output << std::endl;
        }
    }

    for (auto& propertyPair : ownInstanceProperties) {
        BaseClassMeta* owner = propertyPair.second.first;
        PropertyMeta* propertyMeta = propertyPair.second.second;

        if (owner == meta) {
            this->writeProperty(propertyMeta, owner, meta, baseClassInstanceProperties);
        }
    }

    for (auto& propertyPair : ownStaticProperties) {
        BaseClassMeta* owner = propertyPair.second.first;
        PropertyMeta* propertyMeta = propertyPair.second.second;

        if (owner == meta) {
            this->writeProperty(propertyMeta, owner, meta, baseClassInstanceProperties);
        }
    }

    for (auto& propertyPair : protocolInheritedInstanceProperties) {
        BaseClassMeta* owner = propertyPair.second.first;
        PropertyMeta* propertyMeta = propertyPair.second.second;

        bool isDuplicated = ownInstanceProperties.find(propertyMeta->jsName) != ownInstanceProperties.end();
        if (immediateProtocols.find(reinterpret_cast<ProtocolMeta*>(owner)) != immediateProtocols.end() && !isDuplicated) {
            this->writeProperty(propertyMeta, owner, meta, baseClassInstanceProperties);
        }
    }

    for (auto& propertyPair : protocolInheritedStaticProperties) {
        BaseClassMeta* owner = propertyPair.second.first;
        PropertyMeta* propertyMeta = propertyPair.second.second;
        this->writeProperty(propertyMeta, owner, meta, baseClassStaticProperties);
    }

    auto objectAtIndexedSubscript = compoundInstanceMethods.find("objectAtIndexedSubscript");
    if (objectAtIndexedSubscript != compoundInstanceMethods.end()) {
        const Type* retType = objectAtIndexedSubscript->second.second->signature[0];
        std::string indexerReturnType = computeMethodReturnType(retType, meta, true);
        _buffer << "\t[index: number]: " << indexerReturnType << ";" << std::endl;
    }

    if (compoundInstanceMethods.find("countByEnumeratingWithStateObjectsCount") != compoundInstanceMethods.end()) {
        _buffer << "\t[Symbol.iterator](): Iterator<any>;" << std::endl;
    }

    for (auto& methodPair : compoundInstanceMethods) {
        if (methodPair.second.second->getFlags(MethodIsInitializer)) {
            _buffer << std::endl
                    << _docSet.getCommentFor(methodPair.second.second, methodPair.second.first).toString("\t");
            _buffer << "\t" << writeConstructor(methodPair, meta) << std::endl;
        }
    }

    for (auto& methodPair : compoundInstanceMethods) {
        if (ownInstanceProperties.find(methodPair.first) != ownInstanceProperties.end()) {
            continue;
        }

        //        if (methodPair.second.second->getFlags(MethodIsInitializer)) {
        //            continue;
        //        }

        std::string output = writeMethod(methodPair, meta, immediateProtocols, true);
        if (output.size()) {
            _buffer << std::endl
                    << _docSet.getCommentFor(methodPair.second.second, methodPair.second.first).toString("\t");
            _buffer << "\t" << output << std::endl;
        }
    }

    _buffer << "}" << std::endl;
}

void DefinitionWriter::writeProperty(PropertyMeta* propertyMeta, BaseClassMeta* owner, InterfaceMeta* target, CompoundMemberMap<PropertyMeta> baseClassProperties)
{
    _buffer << std::endl
            << _docSet.getCommentFor(propertyMeta, owner).toString("\t");
    _buffer << "\t";

    if (clang::cast<clang::ObjCPropertyDecl>(propertyMeta->declaration)->isClassProperty()) {
        _buffer << "static ";
    }

    if (!propertyMeta->setter) {
        _buffer << "readonly ";
    }

    bool optOutTypeChecking = false;
    auto result = baseClassProperties.find(propertyMeta->jsName);
    if (result != baseClassProperties.end()) {
        optOutTypeChecking = result->second.second->getter->signature[0] != propertyMeta->getter->signature[0];
    }
    _buffer << writeProperty(propertyMeta, target, optOutTypeChecking);

    if (owner != target) {
        _buffer << " // inherited from " << localizeReference(*owner);
    }

    _buffer << std::endl;
}

void DefinitionWriter::getInheritedMembersRecursive(InterfaceMeta* interface,
    CompoundMemberMap<MethodMeta>* staticMethods,
    CompoundMemberMap<MethodMeta>* instanceMethods,
    CompoundMemberMap<PropertyMeta>* staticProperties,
    CompoundMemberMap<PropertyMeta>* instanceProperties)
{
    auto base = interface->base;
    if (!base) {
        return;
    }

    if (staticMethods) {
        for (MethodMeta* method : base->staticMethods) {
            if (staticMethods->find(method->jsName) == staticMethods->end()) {
                staticMethods->emplace(method->jsName, std::make_pair(base, method));
            }
        }
    }

    if (instanceMethods) {
        for (MethodMeta* method : base->instanceMethods) {
            if (instanceMethods->find(method->jsName) == instanceMethods->end()) {
                instanceMethods->emplace(method->jsName, std::make_pair(base, method));
            }
        }
    }

    if (staticProperties) {
        for (PropertyMeta* property : base->staticProperties) {
            if (staticProperties->find(property->jsName) == staticProperties->end()) {
                staticProperties->emplace(property->jsName, std::make_pair(base, property));
            }
        }
    }

    if (instanceProperties) {
        for (PropertyMeta* property : base->instanceProperties) {
            if (instanceProperties->find(property->jsName) == instanceProperties->end()) {
                instanceProperties->emplace(property->jsName, std::make_pair(base, property));
            }
        }
    }

    // accumulate...
    std::unordered_set<ProtocolMeta*> protocols;
    for (auto protocol : base->protocols) {
        getProtocolMembersRecursive(protocol, staticMethods, instanceMethods, staticProperties, instanceProperties, protocols);
    }

    getInheritedMembersRecursive(base, staticMethods, instanceMethods, staticProperties, instanceProperties);
}

void DefinitionWriter::getProtocolMembersRecursive(ProtocolMeta* protocolMeta,
    CompoundMemberMap<MethodMeta>* staticMethods,
    CompoundMemberMap<MethodMeta>* instanceMethods,
    CompoundMemberMap<PropertyMeta>* staticProperties,
    CompoundMemberMap<PropertyMeta>* instanceProperties,
    std::unordered_set<ProtocolMeta*>& visitedProtocols)
{
    visitedProtocols.insert(protocolMeta);

    if (staticMethods) {
        for (MethodMeta* method : protocolMeta->staticMethods) {
            if (staticMethods->find(method->jsName) == staticMethods->end()) {
                staticMethods->emplace(method->jsName, std::make_pair(protocolMeta, method));
            }
        }
    }

    if (instanceMethods) {
        for (MethodMeta* method : protocolMeta->instanceMethods) {
            if (instanceMethods->find(method->jsName) == instanceMethods->end()) {
                instanceMethods->emplace(method->jsName, std::make_pair(protocolMeta, method));
            }
        }
    }

    if (staticProperties) {
        for (PropertyMeta* property : protocolMeta->staticProperties) {
            if (staticProperties->find(property->jsName) == staticProperties->end()) {
                staticProperties->emplace(property->jsName, std::make_pair(protocolMeta, property));
            }
        }
    }

    if (instanceProperties) {
        for (PropertyMeta* property : protocolMeta->instanceProperties) {
            if (instanceProperties->find(property->jsName) == instanceProperties->end()) {
                instanceProperties->emplace(property->jsName, std::make_pair(protocolMeta, property));
            }
        }
    }

    for (ProtocolMeta* protocol : protocolMeta->protocols) {
        getProtocolMembersRecursive(protocol, staticMethods, instanceMethods, staticProperties, instanceProperties, visitedProtocols);
    }
}

void DefinitionWriter::visit(ProtocolMeta* meta)
{
    _buffer << std::endl
            << _docSet.getCommentFor(meta).toString("");
    
    std::string metaName = meta->jsName;
    
    if (DefinitionWriter::applyManualChanges) {
        
        if (metaName == "AudioBuffer") {
            metaName = "_AudioBuffer";
        }
    }

    _buffer << "interface " << metaName;
    std::map<std::string, PropertyMeta*> conformedProtocolsProperties;
    if (meta->protocols.size()) {
        _buffer << " extends ";
        for (size_t i = 0; i < meta->protocols.size(); i++) {
            std::transform(meta->protocols[i]->instanceProperties.begin(), meta->protocols[i]->instanceProperties.end(), std::inserter(conformedProtocolsProperties, conformedProtocolsProperties.end()), [](PropertyMeta* propertyMeta) {
                return std::make_pair(propertyMeta->jsName, propertyMeta);
            });

            _buffer << localizeReference(*meta->protocols[i]);
            if (i < meta->protocols.size() - 1) {
                _buffer << ", ";
            }
        }
    }
    _buffer << " {" << std::endl;

    for (PropertyMeta* property : meta->instanceProperties) {
        bool optOutTypeChecking = conformedProtocolsProperties.find(property->jsName) != conformedProtocolsProperties.end();
        _buffer << std::endl
                << _docSet.getCommentFor(property, meta).toString("\t") << "\t" << writeProperty(property, meta, optOutTypeChecking) << std::endl;
    }

    for (MethodMeta* method : meta->instanceMethods) {
        if (hiddenMethods.find(method->jsName) == hiddenMethods.end()) {
            _buffer << std::endl
                    << _docSet.getCommentFor(method, meta).toString("\t") << "\t" << writeMethod(method, meta) << std::endl;
        }
    }

    _buffer << "}" << std::endl;

    _buffer << "declare var " << metaName << ": {" << std::endl;

    _buffer << std::endl
            << "\tprototype: " << metaName << ";" << std::endl;

    CompoundMemberMap<MethodMeta> compoundStaticMethods;
    for (MethodMeta* method : meta->staticMethods) {
        compoundStaticMethods.emplace(method->jsName, std::make_pair(meta, method));
    }

    std::unordered_set<ProtocolMeta*> protocols;
    for (ProtocolMeta* protocol : meta->protocols) {
        getProtocolMembersRecursive(protocol, &compoundStaticMethods, nullptr, nullptr, nullptr, protocols);
    }

    for (auto& methodPair : compoundStaticMethods) {
        std::string output = writeMethod(methodPair, meta, protocols);
        if (output.size()) {
            MethodMeta* method = methodPair.second.second;
            BaseClassMeta* owner = methodPair.second.first;
            _buffer << std::endl
                    << _docSet.getCommentFor(method, owner).toString("\t");
            _buffer << "\t" << output << std::endl;
        }
    }

    _buffer << "};" << std::endl;
}

std::string DefinitionWriter::writeConstructor(const CompoundMemberMap<MethodMeta>::value_type& initializer,
    const BaseClassMeta* owner)
{
    MethodMeta* method = initializer.second.second;
    assert(method->getFlags(MethodIsInitializer));

    std::ostringstream output;

    if (method->constructorTokens == "") {
        output << "constructor();";
    }
    else {
        std::vector<std::string> ctorTokens;
        StringUtils::split(method->constructorTokens, ':', std::back_inserter(ctorTokens));
        output << "constructor(o: { ";
        for (size_t i = 0; i < ctorTokens.size(); i++) {
            output << ctorTokens[i] << ": ";
            output << (i + 1 < method->signature.size() ? tsifyType(*method->signature[i + 1], true) : "void") << "; ";
        }
        output << "});";
    }

    BaseClassMeta* initializerOwner = initializer.second.first;
    if (initializerOwner != owner) {
        output << " // inherited from " << initializerOwner->jsName;
    }

    return output.str();
}
    
void getClosedGenericsIfAny(Type& type, std::vector<Type*>& params)
{
    if (type.is(TypeInterface)) {
        const InterfaceType& interfaceType = type.as<InterfaceType>();
        for (size_t i = 0; i < interfaceType.typeArguments.size(); i++) {
            getClosedGenericsIfAny(*interfaceType.typeArguments[i], params);
        }
    } else if (type.is(TypeTypeArgument)) {
        TypeArgumentType* typeArg = &type.as<TypeArgumentType>();
        if (typeArg->visit(NameRetrieverVisitor::instanceTs) != "") {
            if (std::find(params.begin(), params.end(), typeArg) == params.end()) {
                params.push_back(typeArg);
            }
        }
    }
}

std::string DefinitionWriter::writeMethod(MethodMeta* meta, BaseClassMeta* owner, bool canUseThisType)
{
    const clang::ObjCMethodDecl& methodDecl = *clang::dyn_cast<clang::ObjCMethodDecl>(meta->declaration);
    auto parameters = methodDecl.parameters();

    std::vector<std::string> parameterNames;
    std::vector<Type*> paramsGenerics;
    std::vector<std::string> ownerGenerics;
    if (owner->is(Interface)) {
        ownerGenerics = getTypeParameterNames(clang::cast<clang::ObjCInterfaceDecl>(static_cast<const InterfaceMeta*>(owner)->declaration));
    }
    
    std::transform(parameters.begin(), parameters.end(), std::back_inserter(parameterNames), [](clang::ParmVarDecl* param) {
        
        return param->getNameAsString();
    });

    for (size_t i = 0; i < parameterNames.size(); i++) {
        getClosedGenericsIfAny(*meta->signature[i+1], paramsGenerics);
        for (size_t n = 0; n < parameterNames.size(); n++) {
            if (parameterNames[i] == parameterNames[n] && i != n) {
                parameterNames[n] += std::to_string(n);
            }
        }
    }
    if (!paramsGenerics.empty()) {
        for (size_t i = 0; i < paramsGenerics.size(); i++) {
            std::string name = paramsGenerics[i]->visit(NameRetrieverVisitor::instanceTs);
            if (std::find(ownerGenerics.begin(), ownerGenerics.end(), name) == ownerGenerics.end())
            {
                paramsGenerics.erase(paramsGenerics.begin() + i);
                i--;
            }
        }
    }

    std::ostringstream output;

    output << meta->jsName;
    bool skipGenerics = false;

    if (DefinitionWriter::applyManualChanges) {
        // HMMutableCharacteristicEvent constructors should not have generics. Default export:
        // static alloc<TriggerValueType>(): HMMutableCharacteristicEvent<TriggerValueType>;
        if (owner->jsName == "HMMutableCharacteristicEvent" && (meta->jsName == "alloc" || meta->jsName == "new")) {
            skipGenerics = true;
        }
    }

    const Type* retType = meta->signature[0];
    
    if (!methodDecl.isInstanceMethod() && owner->is(MetaType::Interface)) {
        if ((retType->is(TypeInstancetype) || DefinitionWriter::hasClosedGenerics(*retType)) && !skipGenerics) {
            output << getTypeParametersStringOrEmpty(
                clang::cast<clang::ObjCInterfaceDecl>(static_cast<const InterfaceMeta*>(owner)->declaration));
        } else if (!paramsGenerics.empty()) {
            output << "<";
            for (size_t i = 0; i < paramsGenerics.size(); i++) {
                auto name = paramsGenerics[i]->visit(NameRetrieverVisitor::instanceTs);
                output << name;
                if (i < paramsGenerics.size() - 1) {
                    output << ", ";
                }
            }
            output << ">";
        }
    }

    if ((owner->type == MetaType::Protocol && methodDecl.getImplementationControl() == clang::ObjCMethodDecl::ImplementationControl::Optional) || (owner->is(MetaType::Protocol) && meta->getFlags(MethodIsInitializer))) {
        output << "?";
    }

    output << "(";

    size_t lastParamIndex = meta->getFlags(::Meta::MetaFlags::MethodHasErrorOutParameter) ? (meta->signature.size() - 1) : meta->signature.size();
    
    if (DefinitionWriter::applyManualChanges) {
        // Default export:
        // copy(sender: any): void;
        // ObjC interface:
        // - (IBAction)copy:(nullable id)sender; -> overrides parent class' (UIView) `copy` method
        if (owner->jsName == "PDFView" && meta->jsName == "copy") {
            lastParamIndex = 0;
        }
    }
    
    for (size_t i = 1; i < lastParamIndex; i++) {
        
        output << sanitizeParameterName(parameterNames[i - 1]) << ": " << tsifyType(*meta->signature[i], true);

        if (i < lastParamIndex - 1) {
            output << ", ";
        }
        
    }
    
    output << "): ";
    if (skipGenerics) {
        output << "any;";
    } else {
        output << computeMethodReturnType(retType, owner, canUseThisType) << ";";
    }
    
    return output.str();
}

std::string DefinitionWriter::writeMethod(CompoundMemberMap<MethodMeta>::value_type& methodPair, BaseClassMeta* owner, const std::unordered_set<ProtocolMeta*>& protocols, bool canUseThisType)
{
    std::ostringstream output;

    BaseClassMeta* memberOwner = methodPair.second.first;
    MethodMeta* method = methodPair.second.second;

    if (hiddenMethods.find(method->jsName) != hiddenMethods.end()) {
        return std::string();
    }

    bool isOwnMethod = memberOwner == owner;
    bool implementsProtocol = protocols.find(static_cast<ProtocolMeta*>(memberOwner)) != protocols.end();
    bool returnsInstanceType = method->signature[0]->is(TypeInstancetype);

    if (isOwnMethod || implementsProtocol || returnsInstanceType) {
        output << writeMethod(method, owner, canUseThisType);
        if (!isOwnMethod && !implementsProtocol) {
            output << " // inherited from " << localizeReference(memberOwner->jsName, memberOwner->module->getFullModuleName());
        }
    }

    return output.str();
}

std::string DefinitionWriter::writeProperty(PropertyMeta* meta, BaseClassMeta* owner, bool optOutTypeChecking)
{
    std::ostringstream output;

    if (hiddenMethods.find(meta->jsName) != hiddenMethods.end()) {
        return std::string();
    }

    // prevent writing out empty property names
    if (meta->jsName.length() == 0) {
        return std::string();
    }

    output << meta->jsName;
    if (owner->is(MetaType::Protocol) && clang::dyn_cast<clang::ObjCPropertyDecl>(meta->declaration)->getPropertyImplementation() == clang::ObjCPropertyDecl::PropertyControl::Optional) {
        output << "?";
    }

    std::string returnType = tsifyType(*meta->getter->signature[0]);
    if (optOutTypeChecking) {
        output << ": any; /*" << returnType << " */";
    }
    else {
        output << ": " << returnType << ";";
    }

    return output.str();
}

void DefinitionWriter::visit(CategoryMeta* meta)
{
}

void DefinitionWriter::visit(FunctionMeta* meta)
{
    const clang::FunctionDecl& functionDecl = *clang::dyn_cast<clang::FunctionDecl>(meta->declaration);

    std::ostringstream params;
    for (size_t i = 1; i < meta->signature.size(); i++) {
        std::string name = sanitizeParameterName(functionDecl.getParamDecl(i - 1)->getNameAsString());
        params << (name.size() ? name : "p" + std::to_string(i)) << ": " << tsifyType(*meta->signature[i], true);
        if (i < meta->signature.size() - 1) {
            params << ", ";
        }
    }

    _buffer << std::endl
            << _docSet.getCommentFor(meta).toString("");
    _buffer << "declare function " << meta->jsName
            << "(" << params.str() << "): ";

    std::string returnName;
    if (meta->name == "UIApplicationMain" || meta->name == "NSApplicationMain" || meta->name == "dispatch_main") {
        returnName = "never";
    }
    else {
        returnName = tsifyType(*meta->signature[0]);
        if (meta->getFlags(MetaFlags::FunctionReturnsUnmanaged)) {
            returnName = "interop.Unmanaged<" + returnName + ">";
        }
    }

    _buffer << returnName << ";";

    _buffer << std::endl;
}

void DefinitionWriter::visit(StructMeta* meta)
{
    
    std::string metaName = meta->jsName;

    if (DefinitionWriter::applyManualChanges) {
        if (metaName == "AudioBuffer") {
            metaName = "_AudioBuffer";
        }
    }
    
    TSComment comment = _docSet.getCommentFor(meta);
    _buffer << std::endl
            << comment.toString("");

    _buffer << "interface " << metaName << " {" << std::endl;
    writeMembers(meta->fields, comment.fields);
    _buffer << "}" << std::endl;

    _buffer << "declare var " << metaName << ": interop.StructType<" << metaName << ">;";

    _buffer << std::endl;
}

void DefinitionWriter::visit(UnionMeta* meta)
{
    TSComment comment = _docSet.getCommentFor(meta);
    _buffer << std::endl
            << comment.toString("");

    _buffer << "interface " << meta->jsName << " {" << std::endl;
    writeMembers(meta->fields, comment.fields);
    _buffer << "}" << std::endl;

    _buffer << std::endl;
}

void DefinitionWriter::writeMembers(const std::vector<RecordField>& fields, std::vector<TSComment> fieldsComments)
{
    for (size_t i = 0; i < fields.size(); i++) {
        if (i < fieldsComments.size()) {
            _buffer << fieldsComments[i].toString("\t");
        }

        // prevent writing empty field names,
        // fixes issue with structs containing emtpy bitfields (ie. __darwin_fp_control)
        if(fields[i].name.length() == 0) {
            continue;
        }

        _buffer << "\t" << fields[i].name << ": " << tsifyType(*fields[i].encoding) << ";" << std::endl;
    }
}

void DefinitionWriter::visit(EnumMeta* meta)
{
    _buffer << std::endl
            << _docSet.getCommentFor(meta).toString("");
    _buffer << "declare const enum " << meta->jsName << " {" << std::endl;

    std::vector<EnumField>& fields = meta->swiftNameFields.size() != 0 ? meta->swiftNameFields : meta->fullNameFields;

    for (size_t i = 0; i < fields.size(); i++) {
        _buffer << std::endl
                << _docSet.getCommentFor(meta->fullNameFields[i].name, MetaType::EnumConstant).toString("\t");
        _buffer << "\t" << fields[i].name << " = " << fields[i].value;
        if (i < fields.size() - 1) {
            _buffer << ",";
        }
        _buffer << std::endl;
    }

    _buffer << "}";
    _buffer << std::endl;
}

void DefinitionWriter::visit(VarMeta* meta)
{
    _buffer << std::endl
            << _docSet.getCommentFor(meta).toString("");
    _buffer << "declare var " << meta->jsName << ": " << tsifyType(*meta->signature) << ";" << std::endl;
}

std::string DefinitionWriter::writeFunctionProto(const std::vector<Type*>& signature)
{
    std::ostringstream output;
    output << "(";

    for (size_t i = 1; i < signature.size(); i++) {
        output << "p" << i << ": " << tsifyType(*signature[i]);
        if (i < signature.size() - 1) {
            output << ", ";
        }
    }

    output << ") => " << tsifyType(*signature[0]);
    return output.str();
}

void DefinitionWriter::visit(MethodMeta* meta)
{
}

void DefinitionWriter::visit(PropertyMeta* meta)
{
}

void DefinitionWriter::visit(EnumConstantMeta* meta)
{
    // The member will be printed by its parent EnumMeta as a TS Enum
    if (meta->isScoped) {
        return;
    }

    _buffer << std::endl;
    _buffer << "declare const " << meta->jsName << ": number;";
    _buffer << std::endl;
}

std::string DefinitionWriter::localizeReference(const std::string& jsName, std::string moduleName)
{
    if (DefinitionWriter::applyManualChanges) {
        if (jsName == "AudioBuffer") {
            return "_AudioBuffer";
        } else if (jsName == "UIEvent") {
            return "_UIEvent";
        }
    }
    return jsName;
}

std::string DefinitionWriter::localizeReference(const ::Meta::Meta& meta)
{
    return localizeReference(meta.jsName, meta.module->getFullModuleName());
}

bool DefinitionWriter::hasClosedGenerics(const Type& type)
{
    if (type.is(TypeInterface)) {
        const InterfaceType& interfaceType = type.as<InterfaceType>();
        return interfaceType.typeArguments.size();
    }

    return false;
}

std::string DefinitionWriter::tsifyType(const Type& type, const bool isFuncParam)
{
    switch (type.getType()) {
    case TypeVoid:
        return "void";
    case TypeBool:
        return "boolean";
    case TypeSignedChar:
    case TypeUnsignedChar:
    case TypeShort:
    case TypeUShort:
    case TypeInt:
    case TypeUInt:
    case TypeLong:
    case TypeULong:
    case TypeLongLong:
    case TypeULongLong:
    case TypeFloat:
    case TypeDouble:
        return "number";
    case TypeUnichar:
    case TypeSelector:
        return "string";
    case TypeCString: {
        std::string res = "string";
        if (isFuncParam) {
            Type typeVoid(TypeVoid);
            res += " | " + tsifyType(::Meta::PointerType(&typeVoid), isFuncParam);
        }
        return res;
    }
    case TypeProtocol:
        return "any /* Protocol */";
    case TypeClass:
        return "typeof " + localizeReference("NSObject", "ObjectiveC");
    case TypeId: {
        const IdType& idType = type.as<IdType>();
        if (idType.protocols.size() == 1) {
            std::string protocol = localizeReference(*idType.protocols[0]);
            // We pass string to be marshalled to NSString which conforms to NSCopying. NSCopying is tricky.
            if (protocol != "NSCopying") {
                return protocol;
            }
        }
        return "any";
    }
    case TypeConstantArray:
    case TypeExtVector:
        return "interop.Reference<" + tsifyType(*type.as<ConstantArrayType>().innerType) + ">";
    case TypeIncompleteArray:
        return "interop.Reference<" + tsifyType(*type.as<IncompleteArrayType>().innerType) + ">";
    case TypePointer: {
        const PointerType& pointerType = type.as<PointerType>();
        return (pointerType.innerType->is(TypeVoid)) ? "interop.Pointer | interop.Reference<any>" : "interop.Pointer | interop.Reference<" + tsifyType(*pointerType.innerType) + ">";
    }
    case TypeBlock:
        return writeFunctionProto(type.as<BlockType>().signature);
    case TypeFunctionPointer:
        return "interop.FunctionReference<" + writeFunctionProto(type.as<FunctionPointerType>().signature)
            + ">";
    case TypeInterface:
    case TypeBridgedInterface: {
        if (type.is(TypeType::TypeBridgedInterface) && type.as<BridgedInterfaceType>().isId()) {
            return tsifyType(IdType());
        }

        const InterfaceMeta& interface = type.is(TypeType::TypeInterface) ? *type.as<InterfaceType>().interface : *type.as<BridgedInterfaceType>().bridgedInterface;
        if (interface.name == "NSNumber") {
            return "number";
        }
        else if (interface.name == "NSString") {
            return "string";
        }
        else if (interface.name == "NSDate") {
            return "Date";
        }
    
    if (DefinitionWriter::applyManualChanges) {
            if (interface.name == "UIEvent") {
                return "_UIEvent";
            }
    }

        std::ostringstream output;
        output << localizeReference(interface);

        bool hasClosedGenerics = DefinitionWriter::hasClosedGenerics(type);
        std::string firstElementType;
        if (hasClosedGenerics) {
            const InterfaceType& interfaceType = type.as<InterfaceType>();
            output << "<";
            for (size_t i = 0; i < interfaceType.typeArguments.size(); i++) {
                std::string argType = tsifyType(*interfaceType.typeArguments[i]);
                output << argType;
                if (i == 0) {
                    firstElementType = argType;//we only need this for NSArray
                }
                if (i < interfaceType.typeArguments.size() - 1) {
                    output << ", ";
                }
            }
            output << ">";
        }
        else {
            // This also translates CFArray to NSArray<any>
            if (auto typeParamList = clang::dyn_cast<clang::ObjCInterfaceDecl>(interface.declaration)->getTypeParamListAsWritten()) {
                output << "<";
                for (size_t i = 0; i < typeParamList->size(); i++) {
                    output << "any";
                    if (i < typeParamList->size() - 1) {
                        output << ", ";
                    }
                }
                output << ">";
            }
        }
        
        if (interface.name == "NSArray" && isFuncParam) {
            if (hasClosedGenerics) {
                std::string arrayType = firstElementType;
                output << " | " << arrayType << "[]";
            } else {
                output << " | any[]";
            }
        }

        return output.str();
    }
    case TypeStruct:
        return localizeReference(*type.as<StructType>().structMeta);
    case TypeUnion:
        return localizeReference(*type.as<UnionType>().unionMeta);
    case TypeAnonymousStruct:
    case TypeAnonymousUnion: {
        std::ostringstream output;
        output << "{ ";

        const std::vector<RecordField>& fields = type.as<AnonymousStructType>().fields;
        for (auto& field : fields) {
            output << field.name << ": " << tsifyType(*field.encoding) << "; ";
        }

        output << "}";
        return output.str();
    }
    case TypeEnum:
        return localizeReference(*type.as<EnumType>().enumMeta);
    case TypeTypeArgument:
        return type.as<TypeArgumentType>().name;
    case TypeVaList:
    case TypeInstancetype:
    default:
        break;
    }

    assert(false);
    return "";
}

std::string DefinitionWriter::computeMethodReturnType(const Type* retType, const BaseClassMeta* owner, bool instanceMember)
{
    std::ostringstream output;
    if (retType->is(TypeInstancetype)) {
        if (instanceMember) {
            output << "this";
        }
        else {
            
            std::string ownerJsName = owner->jsName;
    
            if (DefinitionWriter::applyManualChanges) {
                if (ownerJsName == "UIEvent") {
                    ownerJsName = "_UIEvent";
                }
            }
            
            output << ownerJsName;
            if (owner->is(MetaType::Interface)) {
                output << getTypeParametersStringOrEmpty(clang::cast<clang::ObjCInterfaceDecl>(static_cast<const InterfaceMeta*>(owner)->declaration));
            }
        }
    }
    else {
        output << tsifyType(*retType);
    }

    return output.str();
}

std::string DefinitionWriter::write()
{
    _buffer.clear();
    _importedModules.clear();
    for (::Meta::Meta* meta : _module.second) {
        meta->visit(this);
    }

    std::ostringstream output;

    output << _buffer.str();

    return output.str();
}
}
