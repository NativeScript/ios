#include "metaFile.h"
#include "Utils/fileStream.h"

unsigned int binary::MetaFile::size()
{
    return this->_globalTableSymbols->size();
}

void binary::MetaFile::registerInGlobalTable(const std::string& jsName, binary::MetaFileOffset offset)
{
    this->_globalTableSymbols->add(jsName, offset);
}

binary::MetaFileOffset binary::MetaFile::getFromGlobalTable(const std::string& jsName)
{
    return this->_globalTableSymbols->get(jsName);
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
    std::vector<binary::MetaFileOffset> offsets = this->_globalTableSymbols->serialize(heapWriter);
    globalTableStreamWriter.push_binaryArray(offsets);

    std::vector<MetaFileOffset> modulesOffsets;
    for (std::pair<std::string, MetaFileOffset> pair : this->_topLevelModules)
        modulesOffsets.push_back(pair.second);
    globalTableStreamWriter.push_binaryArray(modulesOffsets);

    // dump heap
    for (auto byteIter = this->_heap->begin(); byteIter != this->_heap->end(); ++byteIter) {
        stream->push_byte(*byteIter);
    }
}
