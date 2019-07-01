#include "binaryWriter.h"

binary::MetaFileOffset binary::BinaryWriter::push_number(long number, int bytesCount)
{
    binary::MetaFileOffset offset = this->_stream->position();

    for (int i = 0; i < bytesCount; i++) {
        int pad = 8 * i;
        uint8_t current = (uint8_t)((number & (255 << pad)) >> pad);
        this->_stream->push_byte(current);
    }

    return offset;
}

binary::MetaFileOffset binary::BinaryWriter::push_string(const std::string& str, bool shouldIntern)
{
    if (shouldIntern && this->uniqueStrings.count(str)) {
        return this->uniqueStrings[str];
    }

    binary::MetaFileOffset offset = this->_stream->position();

    for (char c : str) {
        this->_stream->push_byte((uint8_t)c); // ASCII
    }
    this->_stream->push_byte('\0'); // Null terminated

    if (shouldIntern) {
        this->uniqueStrings.emplace(str, offset);
    }

    return offset;
}

binary::MetaFileOffset binary::BinaryWriter::push_pointer(MetaFileOffset offset)
{
    return this->push_number(offset, sizeof(MetaFileOffset));
}

binary::MetaFileOffset binary::BinaryWriter::push_arrayCount(MetaArrayCount count)
{
    return this->push_number(count, sizeof(MetaArrayCount));
}

binary::MetaFileOffset binary::BinaryWriter::push_binaryArray(std::vector<binary::MetaFileOffset>& binaryArray)
{
    binary::MetaFileOffset offset = this->_stream->position();
    this->push_arrayCount((binary::MetaArrayCount)binaryArray.size());
    for (binary::MetaFileOffset element : binaryArray) {
        this->push_pointer(element);
    }
    return offset;
}

binary::MetaFileOffset binary::BinaryWriter::push_int(int32_t value)
{
    return this->push_number(value, 4);
}

binary::MetaFileOffset binary::BinaryWriter::push_short(int16_t value)
{
    return this->push_number(value, 2);
}

binary::MetaFileOffset binary::BinaryWriter::push_byte(uint8_t value)
{
    binary::MetaFileOffset offset = this->_stream->position();
    this->_stream->push_byte(value);
    return offset;
}
