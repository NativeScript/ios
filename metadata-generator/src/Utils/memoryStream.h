#pragma once

#include "stream.h"
#include <vector>

namespace utils {
/*
     * \class MemoryStream
     * \brief Represents a sequence of bytes stored in memory.
     */
class MemoryStream : public Stream {
private:
    std::vector<uint8_t> _heap;

public:
    
    virtual ~MemoryStream() { }
    /*
         * \brief Returns the number of bytes in this stream.
         */
    virtual unsigned long size() override;

    /*
         * \brief Reads a byte from the current position.
         */
    virtual uint8_t read_byte() override;

    /*
         * \brief Writes a byte to the current position.
         */
    virtual void push_byte(uint8_t b) override;

    /*
         * \brief Returns an iterator pointing to the first element in this stream.
         */
    std::vector<uint8_t>::iterator begin();

    /*
         * \brief Returns an iterator pointing to the past-the-end element in this stream.
         */
    std::vector<uint8_t>::iterator end();
};
}
