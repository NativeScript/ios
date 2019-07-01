//
// Created by Ivan Buhov on 9/4/15.
//
#pragma once
#include "MetaEntities.h"
#include "TypeEntities.h"
#include <clang/AST/Type.h>
#include <string>

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

    std::string getDetailedMessage() const
    {
        return _meta->identificationString() + " : " + this->getMessage();
    }

    const Meta* getMeta()
    {
        return _meta;
    }

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

    std::string getDetailedMessage() const
    {
        return std::string("[Type ") + (_type == nullptr ? "" : _type->getTypeClassName()) + "] : " + this->getMessage();
    }

    const clang::Type* getType()
    {
        return _type;
    }

private:
    const clang::Type* _type;
};
}