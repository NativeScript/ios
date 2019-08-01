#include "binarySerializer.h"
#include "Meta/Utils.h"
#include "binarySerializerPrivate.h"
#include <clang/Basic/FileManager.h>
#include <llvm/Object/Binary.h>
#include <llvm/Object/MachO.h>
#include <llvm/Object/MachOUniversal.h>
#include <llvm/Support/Path.h>
#include <sstream>

uint8_t convertVersion(Meta::Version version)
{
    uint8_t result = 0;
    if (version.Major != -1) {
        result |= version.Major << 3;
        if (version.Minor != -1) {
            result |= version.Minor;
        }
    }
    return result;
}

void binary::BinarySerializer::serializeBase(::Meta::Meta* meta, binary::Meta& binaryMetaStruct)
{
    // name
    bool hasName = meta->name != meta->jsName;
    if (hasName) {
        MetaFileOffset offset1 = this->heapWriter.push_string(meta->jsName);
        MetaFileOffset offset2 = this->heapWriter.push_string(meta->name);
        binaryMetaStruct._names = this->heapWriter.push_pointer(offset1);
        this->heapWriter.push_pointer(offset2);
    }
    else {
        binaryMetaStruct._names = this->heapWriter.push_string(meta->jsName);
    }

    // flags
    uint8_t& flags = binaryMetaStruct._flags;
    if (hasName)
        flags = (uint8_t)(flags | BinaryFlags::HasName);
    if (meta->getFlags(::Meta::MetaFlags::IsIosAppExtensionAvailable))
        flags |= BinaryFlags::IsIosAppExtensionAvailable;

    // module
    clang::Module* topLevelModule = meta->module->getTopLevelModule();
    std::string topLevelModuleName = topLevelModule->getFullModuleName();
    MetaFileOffset moduleOffset = this->file->getFromTopLevelModulesTable(topLevelModuleName);
    if (moduleOffset != 0)
        binaryMetaStruct._topLevelModule = moduleOffset;
    else {
        binary::ModuleMeta moduleMeta{};
        serializeModule(topLevelModule, moduleMeta);
        binaryMetaStruct._topLevelModule = moduleMeta.save(this->heapWriter);
        this->file->registerInTopLevelModulesTable(topLevelModuleName, binaryMetaStruct._topLevelModule);
    }

    // introduced in
    binaryMetaStruct._introduced = convertVersion(meta->introducedIn);
}

void binary::BinarySerializer::serializeBaseClass(::Meta::BaseClassMeta* meta, binary::BaseClassMeta& binaryMetaStruct)
{
    this->serializeBase(meta, binaryMetaStruct);

    std::vector<MetaFileOffset> offsets;

    // instance methods
    std::sort(meta->instanceMethods.begin(), meta->instanceMethods.end(), compareMetasByJsName< ::Meta::MethodMeta>);
    for (::Meta::MethodMeta* methodMeta : meta->instanceMethods) {
        binary::MethodMeta binaryMeta;
        this->serializeMethod(methodMeta, binaryMeta);
        offsets.push_back(binaryMeta.save(this->heapWriter));
    }
    binaryMetaStruct._instanceMethods = this->heapWriter.push_binaryArray(offsets);
    offsets.clear();

    // static methods
    std::sort(meta->staticMethods.begin(), meta->staticMethods.end(), compareMetasByJsName< ::Meta::MethodMeta>);
    for (::Meta::MethodMeta* methodMeta : meta->staticMethods) {
        binary::MethodMeta binaryMeta;
        this->serializeMethod(methodMeta, binaryMeta);
        offsets.push_back(binaryMeta.save(this->heapWriter));
    }
    binaryMetaStruct._staticMethods = this->heapWriter.push_binaryArray(offsets);
    offsets.clear();

    // instance properties
    std::sort(meta->instanceProperties.begin(), meta->instanceProperties.end(), compareMetasByJsName< ::Meta::PropertyMeta>);
    for (::Meta::PropertyMeta* propertyMeta : meta->instanceProperties) {
        binary::PropertyMeta binaryMeta;
        this->serializeProperty(propertyMeta, binaryMeta);
        offsets.push_back(binaryMeta.save(this->heapWriter));
    }
    binaryMetaStruct._instanceProperties = this->heapWriter.push_binaryArray(offsets);
    offsets.clear();

    // static properties
    std::sort(meta->staticProperties.begin(), meta->staticProperties.end(), compareMetasByJsName< ::Meta::PropertyMeta>);
    for (::Meta::PropertyMeta* propertyMeta : meta->staticProperties) {
        binary::PropertyMeta binaryMeta;
        this->serializeProperty(propertyMeta, binaryMeta);
        offsets.push_back(binaryMeta.save(this->heapWriter));
    }
    binaryMetaStruct._staticProperties = this->heapWriter.push_binaryArray(offsets);
    offsets.clear();

    // protocols
    std::sort(meta->protocols.begin(), meta->protocols.end(), compareMetasByJsName< ::Meta::ProtocolMeta>);
    for (::Meta::ProtocolMeta* protocol : meta->protocols) {
        offsets.push_back(this->heapWriter.push_string(protocol->jsName));
    }
    binaryMetaStruct._protocols = this->heapWriter.push_binaryArray(offsets);
    offsets.clear();

    // first initializer index
    int16_t firstInitializerIndex = -1;
    for (std::vector< ::Meta::MethodMeta*>::iterator it = meta->instanceMethods.begin(); it != meta->instanceMethods.end(); ++it) {
        if ((*it)->getFlags(::Meta::MetaFlags::MethodIsInitializer)) {
            firstInitializerIndex = (int16_t)std::distance(meta->instanceMethods.begin(), it);
            break;
        }
    }
    binaryMetaStruct._initializersStartIndex = firstInitializerIndex;
}

void binary::BinarySerializer::serializeMember(::Meta::Meta* meta, binary::MemberMeta& binaryMetaStruct)
{
    this->serializeBase(meta, binaryMetaStruct);
    binaryMetaStruct._flags &= 0b11111000; // this clears the type information written in the lower 3 bits
    
    if (meta->getFlags(::Meta::MetaFlags::MemberIsOptional))
        binaryMetaStruct._flags |= BinaryFlags::MemberIsOptional;

}

void binary::BinarySerializer::serializeMethod(::Meta::MethodMeta* meta, binary::MethodMeta& binaryMetaStruct)
{
    this->serializeMember(meta, binaryMetaStruct);
    
    if (meta->getFlags(::Meta::MetaFlags::MethodIsVariadic))
        binaryMetaStruct._flags |= BinaryFlags::MethodIsVariadic;
    if (meta->getFlags(::Meta::MetaFlags::MethodIsNullTerminatedVariadic))
        binaryMetaStruct._flags |= BinaryFlags::MethodIsNullTerminatedVariadic;
    if (meta->getFlags(::Meta::MetaFlags::MethodOwnsReturnedCocoaObject))
        binaryMetaStruct._flags |= BinaryFlags::MethodOwnsReturnedCocoaObject;
    if (meta->getFlags(::Meta::MetaFlags::MethodHasErrorOutParameter))
        binaryMetaStruct._flags |= BinaryFlags::MethodHasErrorOutParameter;
    if (meta->getFlags(::Meta::MetaFlags::MethodIsInitializer))
        binaryMetaStruct._flags |= BinaryFlags::MethodIsInitializer;

    binaryMetaStruct._encoding = this->typeEncodingSerializer.visit(meta->signature);
    binaryMetaStruct._constructorTokens = this->heapWriter.push_string(meta->constructorTokens);
}

void binary::BinarySerializer::serializeProperty(::Meta::PropertyMeta* meta, binary::PropertyMeta& binaryMetaStruct)
{
    this->serializeMember(meta, binaryMetaStruct);

    if (meta->getter) {
        binaryMetaStruct._flags |= BinaryFlags::PropertyHasGetter;
        binary::MethodMeta binaryMeta;
        this->serializeMethod(meta->getter, binaryMeta);
        binaryMetaStruct._getter = binaryMeta.save(this->heapWriter);
    }
    if (meta->setter) {
        binaryMetaStruct._flags |= BinaryFlags::PropertyHasSetter;
        binary::MethodMeta binaryMeta;
        this->serializeMethod(meta->setter, binaryMeta);
        binaryMetaStruct._setter = binaryMeta.save(this->heapWriter);
    }
}

void binary::BinarySerializer::serializeRecord(::Meta::RecordMeta* meta, binary::RecordMeta& binaryMetaStruct)
{
    this->serializeBase(meta, binaryMetaStruct);

    vector< ::Meta::Type*> typeEncodings;
    vector<MetaFileOffset> nameOffsets;

    for (::Meta::RecordField& recordField : meta->fields) {
        typeEncodings.push_back(recordField.encoding);
        nameOffsets.push_back(this->heapWriter.push_string(recordField.name));
    }

    binaryMetaStruct._fieldNames = this->heapWriter.push_binaryArray(nameOffsets);
    binaryMetaStruct._fieldsEncodings = this->typeEncodingSerializer.visit(typeEncodings);
}

void binary::BinarySerializer::serializeContainer(std::vector<std::pair<clang::Module*, std::vector< ::Meta::Meta*> > >& container)
{
    this->start(container);
    for (std::pair<clang::Module*, std::vector< ::Meta::Meta*> >& module : container) {
        for (::Meta::Meta* meta : module.second) {
            meta->visit(this);
        }
    }
    this->finish(container);
}

static llvm::ErrorOr<bool> isStaticFramework(clang::Module* framework)
{
    using namespace llvm;
    using namespace llvm::object;
    using namespace llvm::sys;

    if (framework->LinkLibraries.size() == 0) {
        return errc::no_such_file_or_directory;
    }

    std::string library = framework->LinkLibraries[0].Library;

    SmallString<128> path;
    if (!path::is_absolute(library)) {
        path::append(path, framework->Directory->getName());
    }
    path::append(path, library);

    if (!fs::exists(path)) {
        path.append(".tbd");
        if (fs::exists(path)) {
            // A TBD file is a text-based file used by Apple. It contains information about a .DYLIB library.
            // TBD files were introduced in Xcode 7 in September 2015 in order to reduce the size of SDKs
            // that come with Xcode by linking to DYLIB libraries instead of storing the actual, larger DYLIB libraries.
            return false;
        }
        
        return errc::no_such_file_or_directory;
    }

    auto isDylib = [](MachOObjectFile* machObjectFile) -> bool {
        uint32_t filetype = (machObjectFile->is64Bit() ? machObjectFile->getHeader64().filetype : machObjectFile->getHeader().filetype);
        return (filetype == MachO::MH_DYLIB || filetype == MachO::MH_DYLIB_STUB || filetype == MachO::MH_DYLINKER);
    };
    
    if (Expected<OwningBinary<Binary> > binaryOrErr = createBinary(path)) {
        Binary& binary = *binaryOrErr.get().getBinary();

        if (MachOUniversalBinary* machoBinary = dyn_cast<MachOUniversalBinary>(&binary)) {
            for (const MachOUniversalBinary::ObjectForArch& object : machoBinary->objects()) {
                if (Expected<std::unique_ptr<MachOObjectFile> > objectFile = object.getAsObjectFile()) {
                    if (MachOObjectFile* machObjectFile = dyn_cast<MachOObjectFile>(objectFile.get().get())) {
                        if (isDylib(machObjectFile)) {
                            return false;
                        }
                    }
                } else if (Expected<std::unique_ptr<Archive> > archive = object.getAsArchive()) {
                    return true;
                }
            }
            // fallthrough and return error (no static, or dynamic library is detected inside the universal binary)
        } else if (MachOObjectFile* machObjectFile = dyn_cast<MachOObjectFile>(&binary)) {
            if (isDylib(machObjectFile)) {
                return false;
            }
        } else if (Archive* archive = dyn_cast<Archive>(&binary)) {
            return true;
        }
    }

    return errc::invalid_argument;
}

void binary::BinarySerializer::serializeModule(clang::Module* module, binary::ModuleMeta& binaryModule)
{
    uint8_t flags = 0;
    if (module->isPartOfFramework()) {
        // Sometimes the framework binary is missing in the SDK but exists on the device.
        // System frameworks are always shared, so there's no need to check them anyways.
        if (module->IsSystem) {
            flags |= 1;
        } else {
            llvm::ErrorOr<bool> isStatic = isStaticFramework(module);
            assert(isStatic.getError().value() == 0);

            bool isDynamic = isStatic.getError().value() == 0 && !isStatic.get();
            if (isDynamic) {
                flags |= 1;
            }
        }
    }
    if (module->IsSystem) {
        flags |= 2;
    }
    binaryModule._flags |= flags;
    binaryModule._name = this->heapWriter.push_string(module->getFullModuleName());
    std::vector<clang::Module::LinkLibrary> libraries;
    ::Meta::Utils::getAllLinkLibraries(module, libraries);
    std::vector<MetaFileOffset> librariesOffsets;
    for (clang::Module::LinkLibrary lib : libraries) {
        binary::LibraryMeta libMeta;
        serializeLibrary(&lib, libMeta);
        librariesOffsets.push_back(libMeta.save(this->heapWriter));
    }
    binaryModule._libraries = this->heapWriter.push_binaryArray(librariesOffsets);
}

void binary::BinarySerializer::serializeLibrary(clang::Module::LinkLibrary* library, binary::LibraryMeta& binaryLib)
{
    uint8_t flags = 0;
    if (library->IsFramework)
        flags |= 1;
    binaryLib._flags = flags;
    binaryLib._name = this->heapWriter.push_string(library->Library);
}

void binary::BinarySerializer::start(std::vector<std::pair<clang::Module*, std::vector< ::Meta::Meta*> > >& container)
{
}

void binary::BinarySerializer::finish(std::vector<std::pair<clang::Module*, std::vector< ::Meta::Meta*> > >& container)
{
}

void binary::BinarySerializer::visit(::Meta::InterfaceMeta* meta)
{
    binary::InterfaceMeta binaryStruct;
    serializeBaseClass(meta, binaryStruct);
    if (meta->base != nullptr) {
        binaryStruct._baseName = this->heapWriter.push_string(meta->base->jsName);
    }
    this->file->registerInGlobalTable(meta->jsName, binaryStruct.save(this->heapWriter));
}

void binary::BinarySerializer::visit(::Meta::ProtocolMeta* meta)
{
    binary::ProtocolMeta binaryStruct;
    serializeBaseClass(meta, binaryStruct);
    this->file->registerInGlobalTable(meta->jsName, binaryStruct.save(this->heapWriter));
}

void binary::BinarySerializer::visit(::Meta::CategoryMeta* meta)
{
    // we shouldn't have categories in the binary file
}

void binary::BinarySerializer::visit(::Meta::FunctionMeta* meta)
{
    binary::FunctionMeta binaryStruct;
    serializeBase(meta, binaryStruct);

    if (meta->getFlags(::Meta::MetaFlags::FunctionIsVariadic))
        binaryStruct._flags |= BinaryFlags::FunctionIsVariadic;
    if (meta->getFlags(::Meta::MetaFlags::FunctionOwnsReturnedCocoaObject))
        binaryStruct._flags |= BinaryFlags::FunctionOwnsReturnedCocoaObject;
    if (meta->getFlags(::Meta::MetaFlags::FunctionReturnsUnmanaged))
        binaryStruct._flags |= BinaryFlags::FunctionReturnsUnmanaged;

    binaryStruct._encoding = this->typeEncodingSerializer.visit(meta->signature);
    this->file->registerInGlobalTable(meta->jsName, binaryStruct.save(this->heapWriter));
}

void binary::BinarySerializer::visit(::Meta::StructMeta* meta)
{
    binary::StructMeta binaryStruct;
    serializeRecord(meta, binaryStruct);
    this->file->registerInGlobalTable(meta->jsName, binaryStruct.save(this->heapWriter));
}

void binary::BinarySerializer::visit(::Meta::UnionMeta* meta)
{
    binary::UnionMeta binaryStruct;
    serializeRecord(meta, binaryStruct);
    this->file->registerInGlobalTable(meta->jsName, binaryStruct.save(this->heapWriter));
}

void binary::BinarySerializer::visit(::Meta::EnumMeta* meta)
{
    binary::JsCodeMeta binaryStruct;
    serializeBase(meta, binaryStruct);

    // generate JsCode from enum names and values
    std::ostringstream jsCodeStream;
    jsCodeStream << "__tsEnum({";
    bool isFirstField = true;
    for (::Meta::EnumField& field : meta->swiftNameFields) {
        jsCodeStream << (isFirstField ? "" : ",") << "\"" << field.name << "\":" << field.value;
        isFirstField = false;
    }
    for (::Meta::EnumField& field : meta->fullNameFields) {
        jsCodeStream << (isFirstField ? "" : ",") << "\"" << field.name << "\":" << field.value;
        isFirstField = false;
    }
    jsCodeStream << "})";

    binaryStruct._jsCode = this->heapWriter.push_string(jsCodeStream.str());
    this->file->registerInGlobalTable(meta->jsName, binaryStruct.save(this->heapWriter));
}

void binary::BinarySerializer::visit(::Meta::VarMeta* meta)
{
    if (meta->hasValue) {
        // serialize as JsCodeMeta
        binary::JsCodeMeta binaryStruct;
        serializeBase(meta, binaryStruct);
        binaryStruct._jsCode = this->heapWriter.push_string(meta->value);
        this->file->registerInGlobalTable(meta->jsName, binaryStruct.save(this->heapWriter));
    }
    else {
        // serialize as VarMeta
        binary::VarMeta binaryStruct;
        serializeBase(meta, binaryStruct);
        unique_ptr<binary::TypeEncoding> binarySignature = meta->signature->visit(this->typeEncodingSerializer);
        binaryStruct._encoding = binarySignature->save(this->heapWriter);
        this->file->registerInGlobalTable(meta->jsName, binaryStruct.save(this->heapWriter));
    }
}

void binary::BinarySerializer::visit(::Meta::EnumConstantMeta* meta)
{
    binary::JsCodeMeta binaryStruct;
    serializeBase(meta, binaryStruct);

    binaryStruct._jsCode = this->heapWriter.push_string(meta->value);
    this->file->registerInGlobalTable(meta->jsName, binaryStruct.save(this->heapWriter));
}

void binary::BinarySerializer::visit(::Meta::PropertyMeta* meta)
{
}

void binary::BinarySerializer::visit(::Meta::MethodMeta* meta)
{
}
