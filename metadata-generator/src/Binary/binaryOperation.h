#pragma once

#include "Utils/stream.h"

namespace binary {
class BinaryOperation {
protected:
    std::shared_ptr<utils::Stream> _stream;

public:
    BinaryOperation(std::shared_ptr<utils::Stream> stream)
    {
        this->_stream = stream;
    }

    utils::Stream* baseStream()
    {
        return this->_stream.get();
    }
};
}
