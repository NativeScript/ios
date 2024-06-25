//
// Created by Ivan Buhov on 11/6/15.
//

#ifndef METADATAGENERATOR_DOCSETPARSER_H
#define METADATAGENERATOR_DOCSETPARSER_H

#include <Meta/MetaEntities.h>

struct _xmlDoc;

namespace Meta {
class Meta;
}

namespace TypeScript {

// \brief A structure, representing a TypeScript comment.
struct TSComment {
    /*
     * \brief A brief description of the symbol.
     */
    std::string description;
    
    Meta::Version introducedIn = UNKNOWN_VERSION;
    Meta::Version obsoletedIn = UNKNOWN_VERSION;
    Meta::Version deprecatedIn = UNKNOWN_VERSION;

    /*
     * \brief An optional list of parameters. Useful in method and function comments.
     */
    std::vector<std::pair<std::string, std::string> > params;

    /*
     * \brief An optional list of field comments. Useful in struct and union comments.
     */
    std::vector<TSComment> fields;

    /*
     * \brief Converts the comment into its string representation.
     * \param linePrefix Will prefix every line in the output with this value. Useful in case of tabulation.
     */
    std::string toString(std::string linePrefix);
};
/*
 * \class DocSetManager
 * \brief The DocSetManager is responsible for parsing and retrieving documentation from .docset packages. It parses the XML files in the .docset and generates TypeScript comments from them.
 */
class DocSetManager {
public:
    DocSetManager(std::string docsetPath)
        : docsetPath(docsetPath)
        , tokensPath(docsetPath + "/Contents/Resources/Tokens")
    {
    }

    /*
     * \brief Retrieves a TypeScript comment for a given symbol. If the symbol is a member (e.g. method or property) a parent must be supplied, too.
     * \param meta The symbol for which TypeScript comment will be generated.
     * \param parent If the first parameter is method or property, a parent (the containing Interface or Protocol) must be passed, too, in order to find the correct XML file location.
     */
    TSComment getCommentFor(Meta::Meta* meta, Meta::Meta* parent = nullptr);

    TSComment getCommentFor(std::string name, Meta::MetaType type, std::string parentName = "", Meta::MetaType parentType = Meta::MetaType::Undefined);

private:
    /*
     * \brief Tries to find the location and parses the XML documentation file for a symbol with the given name and type. Null is returned if unable to find a doc file.
     * \param name The name of the symbol.
     * \param type The type of the symbol. Depending on the type, different foldeers will be examined.
     * \param parentName If the symbol is method or property, a parent (the containing Interface or Protocol) must be passed, too, in order to find the correct XML file location.
     * \param parentType The type of the parent symbol.
     */
    _xmlDoc* getXmlDocFileFor(std::string name, Meta::MetaType type, std::string parentName = "", Meta::MetaType parentType = Meta::MetaType::Undefined);

    std::string docsetPath;
    std::string tokensPath;
};
}

#endif //METADATAGENERATOR_DOCSETPARSER_H
