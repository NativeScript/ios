#pragma once

#include "binaryStructures.h"
#include <string>
#include <vector>

namespace binary {
/*
     * \class BinaryHashtable
     * \brief This class implements a hash table, which maps jsName keys to offsets.
     *
     * Hashing is done using JSCore \c StringHasher
     */
class BinaryHashtable {
private:
    std::vector<std::vector<std::tuple<std::string, MetaFileOffset> > > elements;

    unsigned int hash(std::string value);

public:
    /*
         * \brief Constructs \c BinaryHashtable with the specified size.
         * \param size Number of elements this hash table will contain.
         */
    BinaryHashtable(int size)
    {
        this->elements = std::vector<std::vector<std::tuple<std::string, MetaFileOffset> > >((unsigned long)((size * 1.25) + .5));
    }

    /*
         * \brief Maps the specified jsName to the specified offset in this hashtable.
         * \param jsName The jsName of the element
         * \param offset The offset in the heap
         */
    void add(std::string jsName, MetaFileOffset offset);

    /*
         * \brief Returns the offset to which the specified jsName is mapped.
         * \param jsName The jsName of the element
         * \return The offset in the heap
         */
    MetaFileOffset get(const std::string& jsName);

    /*
         * \brief Returns the number of keys in this hashtable.
         */
    unsigned int size();

    /*
         * \brief Serializes this hashtable in binary format.
         * The inner representation is serialized as a vectors of vectors in the heap and
         * pointers to this vectors are returned.
         * \param heapWriter Reference to a \c BinaryWriter that will be used for serialization
         * \returns vector of offsets pointing to vectors in the heap
         */
    std::vector<MetaFileOffset> serialize(BinaryWriter& heapWriter);
};
}