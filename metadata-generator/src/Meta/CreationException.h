//
// Created by Ivan Buhov on 9/4/15.
//
#pragma once
#include "MetaEntities.h"
#include "TypeEntities.h"
#include <clang/AST/Type.h>
#include <string>


#define DEFINE_POLYMORPHIC_THROW \
virtual void polymorhicThrow() override { \
    throw *this; \
}


#define POLYMORPHIC_THROW(ex) do \
{ \
    ex->polymorhicThrow(); \
    throw std::logic_error("polymorphicThrow should never return"); \
} while(false)

namespace Meta {
class CreationException {
public:
    static std::string constructMessage(std::string outerMessage, std::string innerMessage)
    {
        return outerMessage + " --> " + innerMessage;
    }

    CreationException(std::string message, bool isError)
        : _message(message)
        , _isError(isError)
    {
    }
    
    virtual ~CreationException() { }

    virtual void polymorhicThrow() = 0;
    
    std::string getMessage() const
    {
        return _message;
    }

    virtual std::string getDetailedMessage() const
    {
        return getMessage();
    }

    bool isError() const
    {
        return _isError;
    }

private:
    std::string _message;
    bool _isError;
};

class MetaCreationException : public CreationException {
public:
    MetaCreationException(const Meta* meta, std::string message, bool isError)
        : CreationException(message, isError)
        , _meta(meta)
    {
    }

    std::string getDetailedMessage() const override
    {
        return _meta->identificationString() + " : " + this->getMessage();
    }

    const Meta* getMeta()
    {
        return _meta;
    }

    DEFINE_POLYMORPHIC_THROW;

private:
    const Meta* _meta;
};

class TypeCreationException : public CreationException {
public:
    TypeCreationException(const clang::Type* type, std::string message, bool isError)
        : CreationException(message, isError)
        , _type(type)
    {
    }

    std::string getDetailedMessage() const override
    {
        return std::string("[Type ") + (_type == nullptr ? "" : _type->getTypeClassName()) + "] : " + this->getMessage();
    }

    const clang::Type* getType()
    {
        return _type;
    }

    DEFINE_POLYMORPHIC_THROW;

private:
    const clang::Type* _type;
};
}
