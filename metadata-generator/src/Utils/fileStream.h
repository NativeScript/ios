#pragma once

#include "stream.h"
#include <fstream>
#include <ostream>
#include <vector>

namespace utils {
/*
     * \class FileStream
     * \brief Represents a sequence of bytes stored in file.
     */
class FileStream : public Stream {
private:
    std::fstream file;

    FileStream() {}
    
public:
    virtual ~FileStream() {}
    
    /*
         * \brief Opens the file identified by argument filename, associating it with the stream object,
         * so that input/output operations are performed on its content.
         * \param filename
         * \param mode Specifies the opening mode
         * \return \c FileStream object representing the file
         */
    static std::shared_ptr<FileStream> open(std::string filename, std::ios::openmode mode);

    /*
         * \brief Closes the file currently associated with the object, disassociating it from the stream.
         *
         * Any pending output sequence is written to the file.
         */
    void close();

    /*
         * \brief Gets the current position in this file.
         */
    virtual unsigned long position() override;

    /*
         * \brief Sets the current position in this file.
         */
    virtual void set_position(unsigned long p) override;

    /*
         * \brief Returns the number of bytes in this file.
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
};
}
