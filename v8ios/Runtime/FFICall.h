#ifndef FFICall_h
#define FFICall_h

#include <malloc/malloc.h>
#include <map>
#include "Metadata.h"
#include "ffi.h"

namespace tns {

class BaseFFICall {
public:
    BaseFFICall(uint8_t* buffer, size_t returnOffset): buffer_(buffer), returnOffset_(returnOffset) { }

    ~BaseFFICall() {
        free(this->buffer_);
    }

    void* ResultBuffer() {
        return this->buffer_ + this->returnOffset_;
    }

    template <typename T>
    T& GetResult() {
        return *static_cast<T*>(this->ResultBuffer());
    }
protected:
    size_t returnOffset_;
    uint8_t* buffer_;
};

class FFICall: public BaseFFICall {
public:
    FFICall(const TypeEncoding* typeEncoding, const int initialParameterIndex, const int argsCount);

    ~FFICall() {
    }

    static ffi_type* GetArgumentType(const TypeEncoding* typeEncoding);
    static ffi_type* GetStructFFIType(const StructMeta* structMeta, std::map<std::string, std::pair<const TypeEncoding*, size_t>>& offsets);
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
private:
    static std::map<const TypeEncoding*, ffi_cif*> cifCache_;

    std::vector<size_t> argValueOffsets_;
    size_t argsArrayOffset_;
    size_t stackSize_;
    void** argsArray_;
};

}

#endif /* FFICall_h */
