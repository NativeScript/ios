#ifndef FFICall_h
#define FFICall_h

#include <malloc/malloc.h>
#include <map>
#include "Metadata.h"
#include "DataWrapper.h"
#include "libffi.h"

namespace tns {

class BaseCall {
public:
    BaseCall(uint8_t* buffer, size_t returnOffset = 0): buffer_(buffer), returnOffset_(returnOffset) { }

    ~BaseCall() {
    }

    void* ResultBuffer() {
        return this->buffer_ + this->returnOffset_;
    }

    template <typename T>
    T& GetResult() {
        return *static_cast<T*>(this->ResultBuffer());
    }
protected:
    uint8_t* buffer_;
    size_t returnOffset_;
};

class FFICall: public BaseCall {
public:
    FFICall(ffi_cif* cif): BaseCall(nullptr) {
        unsigned int argsCount = cif->nargs;
        size_t stackSize = 0;

        if (argsCount > 0) {
            stackSize = malloc_good_size(sizeof(void* [argsCount]));
        }

        this->returnOffset_ = stackSize;

        stackSize += malloc_good_size(std::max(cif->rtype->size, sizeof(ffi_arg)));

        std::vector<size_t> argValueOffsets;
        for (size_t i = 0; i < argsCount; i++) {
            argValueOffsets.push_back(stackSize);
            ffi_type* argType = cif->arg_types[i];
            stackSize += malloc_good_size(std::max(argType->size, sizeof(ffi_arg)));
        }

        this->buffer_ = reinterpret_cast<uint8_t*>(calloc(1, stackSize));

        this->argsArray_ = reinterpret_cast<void**>(this->buffer_);
        for (size_t i = 0; i < argsCount; i++) {
            this->argsArray_[i] = this->buffer_ + argValueOffsets[i];
        }
    }

    ~FFICall() {
        free(this->buffer_);
    }

    static ffi_type* GetArgumentType(const TypeEncoding* typeEncoding);
    static ffi_type* GetStructFFIType(const StructMeta* structMeta, std::vector<StructField>& fields);
    static ffi_cif* GetCif(const TypeEncoding* typeEncoding, const int initialParameterIndex, const int argsCount);

    void* ArgumentBuffer(unsigned index) {
        return this->argsArray_[index];
    }

    void** ArgsArray() {
        return this->argsArray_;
    }
private:
    static std::map<const TypeEncoding*, ffi_cif*> cifCache_;
    void** argsArray_;
};

}

#endif /* FFICall_h */
