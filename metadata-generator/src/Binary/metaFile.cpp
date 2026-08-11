#include "metaFile.h"
#include "Utils/fileStream.h"

unsigned int binary::MetaFile::size()
{
    return this->_globalTableSymbolsJs->size();
}

void binary::MetaFile::registerInGlobalTables(const ::Meta::Meta& meta, binary::MetaFileOffset offset)
{
    this->_globalTableSymbolsJs->add(meta.jsName, offset);

    auto& nativeTable = (meta.type == ::Meta::MetaType::Protocol) ? this->_globalTableSymbolsNativeProtocols : this->_globalTableSymbolsNativeInterfaces;

    nativeTable->add(meta.name, offset);

    if (!meta.demangledName.empty()) {
        nativeTable->add(meta.demangledName, offset);
    }
}

binary::MetaFileOffset binary::MetaFile::getFromGlobalTable(const std::string& jsName)
{
    return this->_globalTableSymbolsJs->get(jsName);
}

void binary::MetaFile::registerInTopLevelModulesTable(const std::string& moduleName, binary::MetaFileOffset offset)
{
    this->_topLevelModules.insert(std::pair<std::string, MetaFileOffset>(moduleName, offset));
}

binary::MetaFileOffset binary::MetaFile::getFromTopLevelModulesTable(const std::string& moduleName)
{
    std::map<std::string, MetaFileOffset>::iterator it = this->_topLevelModules.find(moduleName);
    return (it != this->_topLevelModules.end()) ? it->second : 0;
}

bool binary::MetaFile::internClassName(const std::string& name,
                                       binary::BinaryWriter& heapWriter,
                                       uint16_t& index) {
  auto it = this->_classNameIndices.find(name);
  if (it != this->_classNameIndices.end()) {
    index = it->second;
    return true;
  }

  // The index is serialized as uint16, so the table cannot grow past 2^16.
  if (this->_classNames.size() > UINT16_MAX) {
    return false;
  }

  index = (uint16_t)this->_classNames.size();
  this->_classNames.push_back(heapWriter.push_string(name));
  this->_classNameIndices.emplace(name, index);
  return true;
}

binary::BinaryWriter binary::MetaFile::heap_writer()
{
    return binary::BinaryWriter(this->_heap);
}

binary::BinaryReader binary::MetaFile::heap_reader()
{
    return binary::BinaryReader(this->_heap);
}

void binary::MetaFile::save(string filename)
{
    std::shared_ptr<utils::FileStream> fileStream = utils::FileStream::open(filename, ios::out | ios::binary | ios::trunc);
    this->save(fileStream);
    fileStream->close();
}

void binary::MetaFile::save(std::shared_ptr<utils::Stream> stream)
{
    // dump global table
    BinaryWriter globalTableStreamWriter = BinaryWriter(stream);
    BinaryWriter heapWriter = this->heap_writer();
    std::vector<binary::MetaFileOffset> jsOffsets = this->_globalTableSymbolsJs->serialize(heapWriter);
    globalTableStreamWriter.push_binaryArray(jsOffsets, /*shouldIntern*/ false);

    std::vector<binary::MetaFileOffset> nativeProtocolOffsets = this->_globalTableSymbolsNativeProtocols->serialize(heapWriter);
    globalTableStreamWriter.push_binaryArray(nativeProtocolOffsets,
                                             /*shouldIntern*/ false);

    std::vector<binary::MetaFileOffset> nativeInterfaceOffsets = this->_globalTableSymbolsNativeInterfaces->serialize(heapWriter);
    globalTableStreamWriter.push_binaryArray(nativeInterfaceOffsets,
                                             /*shouldIntern*/ false);

    std::vector<MetaFileOffset> modulesOffsets;
    for (std::pair<std::string, MetaFileOffset> pair : this->_topLevelModules)
        modulesOffsets.push_back(pair.second);
    globalTableStreamWriter.push_binaryArray(modulesOffsets,
                                             /*shouldIntern*/ false);

    // Must stay the last table before the heap: the runtime locates the heap by
    // walking these tables in order (MetaFile::heap in Metadata.h).
    globalTableStreamWriter.push_binaryArray(this->_classNames,
                                             /*shouldIntern*/ false);

    // dump heap
    for (auto byteIter = this->_heap->begin(); byteIter != this->_heap->end(); ++byteIter) {
        stream->push_byte(*byteIter);
    }
}
