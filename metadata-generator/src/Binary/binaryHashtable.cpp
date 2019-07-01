#include "binaryHashtable.h"
#include "Utils/StringHasher.h"
#include "metaFile.h"

unsigned int binary::BinaryHashtable::hash(std::string value)
{
    StringHasher hasher;
    hasher.addCharactersAssumingAligned(value.c_str(), value.size());
    return hasher.hashWithTop8BitsMasked();
}

void binary::BinaryHashtable::add(std::string jsName, binary::MetaFileOffset offset)
{
    unsigned int tableIndex = this->hash(jsName) % this->size();
    this->elements[tableIndex].push_back(std::make_tuple(jsName, offset));
}

binary::MetaFileOffset binary::BinaryHashtable::get(const std::string& jsName)
{
    unsigned int tableIndex = this->hash(jsName) % this->size();

    for (std::tuple<std::string, MetaFileOffset>& tuple : this->elements[tableIndex]) {
        if (std::get<0>(tuple) == jsName) {
            return std::get<1>(tuple);
        }
    }

    return 0;
}

unsigned int binary::BinaryHashtable::size()
{
    return (unsigned int)this->elements.size();
}

std::vector<binary::MetaFileOffset> binary::BinaryHashtable::serialize(binary::BinaryWriter& heapWriter)
{
    std::vector<binary::MetaFileOffset> offsets;

    for (std::vector<std::tuple<std::string, MetaFileOffset> > element : this->elements) {
        if (element.size() > 0) {
            std::vector<MetaFileOffset> elementOffsets;
            for (std::tuple<std::string, MetaFileOffset>& tuple : element) {
                elementOffsets.push_back(std::get<1>(tuple));
            }

            offsets.push_back(heapWriter.push_binaryArray(elementOffsets));
        } else {
            offsets.push_back(0);
        }
    }

    return offsets;
}
