#pragma once

#include "Utils/stream.h"
#include "binaryOperation.h"
#include "binaryStructures.h"
#include <map>
#include <string>

namespace binary {
/*
     * \class BinaryWriter
     * \brief Writes primitive data types to a given stream.
     */
class BinaryWriter : public BinaryOperation {
private:
    std::map<std::string, MetaFileOffset> uniqueStrings;

    MetaFileOffset push_number(long number, int bytesCount);

public:
    /*
         * \brief Constructs \c BinaryWriter for a given stream.
         * \param stream The stream from which data will be read
         */
    BinaryWriter(std::shared_ptr<utils::Stream> stream)
        : BinaryOperation(stream)
    {
    }

    /*
         * \brief Writes a nil terminated string.
         * \param str
         * \param shouldIntern Specifies if this string should be unique in this stream. Default \c true
         */
    MetaFileOffset push_string(const std::string& str, bool shouldIntern = true);

    /*
         * \brief Writes a pointer.
         * \param offset
         */
    MetaFileOffset push_pointer(MetaFileOffset offset);

    /*
         * \brief Writes an array count.
         * \param count
         */
    MetaFileOffset push_arrayCount(MetaArrayCount count);

    /*
         * \brief Writes a binary array
         * A binary array is a collection of offsets
         * \param binaryArray
         */
    MetaFileOffset push_binaryArray(std::vector<MetaFileOffset>& binaryArray);

    /*
         * \brief Writes a 4 byte integer.
         * \param value
         */
    MetaFileOffset push_int(int32_t value);

    /*
         * \brief Writes a 2 byte short.
         * \param value
         */
    MetaFileOffset push_short(int16_t value);

    /*
         * \brief Writes a single byte.
         * \param value
         */
    MetaFileOffset push_byte(uint8_t value);
};
}