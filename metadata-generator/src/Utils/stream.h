#pragma once

#include <stdint.h>
#include <vector>

namespace utils {
/*
     * \class Stream
     * \brief Represents a sequence of bytes
     */
class Stream {
protected:
    unsigned long _position;

public:
    /*
         * \brief Gets the current position in this stream.
         */
    virtual unsigned long position()
    {
        return this->_position;
    }

    /*
         * \brief Sets the current position in this stream.
         */
    virtual void set_position(unsigned long p)
    {
        this->_position = p;
    }

    /*
         * \brief Returns the number of bytes in this stream.
         *
         * This is a pure virtual function
         */
    virtual unsigned long size() = 0;

    /*
         * \brief Reads a byte from the current position.
         *
         * This is a pure virtual function
         */
    virtual uint8_t read_byte() = 0;

    /*
         * \brief Writes a byte to the current position.
         *
         * This is a pure virtual function
         */
    virtual void push_byte(uint8_t b) = 0;

    virtual void operator<<(uint8_t b)
    {
        this->push_byte(b);
    }
};
}