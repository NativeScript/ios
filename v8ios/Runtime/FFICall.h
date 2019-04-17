#ifndef FFICall_h
#define FFICall_h

#include <malloc/malloc.h>
#include <map>
#include "Metadata.h"
#include "ffi.h"

namespace tns {

class FFICall {
public:
    FFICall(const TypeEncoding* typeEncoding, const int initialParameterIndex, const int argsCount);

    ~FFICall() {
        free(this->buffer_);
    }

    static ffi_type* GetArgumentType(const TypeEncoding* typeEncoding);
    static ffi_cif* GetCif(const TypeEncoding* typeEncoding, const int initialParameterIndex, const int argsCount);

    void* ArgumentBuffer(unsigned index) {
        return this->buffer_ + this->argValueOffsets_[index];
    }

    template <typename T>
    void SetArgument(unsigned index, T value) {
        *static_cast<T*>(ArgumentBuffer(index)) = value;
    }

    void** ArgsArray() {
        return this->argsArray_;
    }

    void* ResultBuffer() {
        return this->buffer_ + this->returnOffset_;
    }

    template <typename T>
    T& GetResult() {
        return *static_cast<T*>(this->ResultBuffer());
    }
private:
    static std::map<const TypeEncoding*, ffi_cif*> cifCache_;

    std::vector<size_t> argValueOffsets_;
    size_t argsArrayOffset_;
    size_t returnOffset_;
    size_t stackSize_;
    uint8_t* buffer_;
    void** argsArray_;
};

}

#endif /* FFICall_h */
