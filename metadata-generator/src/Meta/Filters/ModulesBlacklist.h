//
//  ModulesBlacklist.h
//  MetadataGenerator
//
//  Created by Martin Bekchiev on 13.01.20.
//

#ifndef ModulesBlacklist_h
#define ModulesBlacklist_h

#include <vector>
#include <fstream>
#include <sstream>
#include <llvm/ADT/StringRef.h>
#include <llvm/Support/Regex.h>

namespace Meta {

class ModulesBlacklist {
private:
    struct ModuleAndSymbolNamePatterns {
        std::string modulePattern;
        std::string symbolPattern;
        
        std::string toString() {
            return this->modulePattern + ":" + this->symbolPattern;
        }
    };
    typedef std::vector<ModuleAndSymbolNamePatterns> ModuleAndSymbolNamePatternsList;

public:
    ModulesBlacklist(std::string& whitelistFileName, std::string& blacklistFileName) {
        this->_whitelistDefined = !whitelistFileName.empty();
        fillPatternsFromFile(whitelistFileName, /*r*/this->_whitelist);
        fillPatternsFromFile(blacklistFileName, /*r*/this->_blacklist);
    }

    bool shouldBlacklist(std::string moduleName, std::string symbolName, std::string& enabledBy, std::string& disabledBy) {
        auto findMatchingPattern = [&moduleName, &symbolName](ModuleAndSymbolNamePatternsList& v) {
            return std::find_if(v.begin(), v.end(), [&moduleName, &symbolName](ModuleAndSymbolNamePatterns& item) {
                return
                    (item.modulePattern.empty() ||
                     match(item.modulePattern.c_str(), moduleName.c_str()))
                &&
                    (item.symbolPattern.empty() ||
                     match(item.symbolPattern.c_str(), symbolName.c_str()));
            });
        };
        
        bool enabledByWhitelist = true;
        if (this->_whitelistDefined) {
            auto it = findMatchingPattern(this->_whitelist);
            enabledByWhitelist = it != this->_whitelist.end();
            if (enabledByWhitelist) {
                enabledBy = it->toString();
            }
        }
        
        auto itBlacklist = findMatchingPattern(this->_blacklist);
        bool disabledByBlacklist = itBlacklist != this->_blacklist.end();
        if (disabledByBlacklist) {
            disabledBy = itBlacklist->toString();
        }

        return disabledByBlacklist || !enabledByWhitelist;
    }

private:
    // Taken from https://www.geeksforgeeks.org/wildcard-character-matching/
    static bool match(const char* pattern, const char* string)
    {
        // If we reach at the end of both strings, we are done
        if (*pattern == '\0' && *string == '\0')
            return true;
        
        // pattern "*" matches everything, done checking
        if (pattern[0] == '*' && pattern[1] == '\0')
            return true;
        
        // Make sure that the characters after '*' are present
        // in second string. This function assumes that the first
        // string will not contain two consecutive '*'
        if (*pattern == '*' && *(pattern+1) != '\0' && *string == '\0')
            return false;
      
        // If the first string contains '?', or current characters
        // of both strings match
        if (*pattern == '?' || *pattern == *string)
            return match(pattern+1, string+1);
      
        // If there is *, then there are two possibilities
        // a) We consider current character of second string
        // b) We ignore current character of second string.
        if (*pattern == '*')
            return match(pattern+1, string) || match(pattern, string+1);
        return false;
    }
    
    static void fillPatternsFromFile(const std::string& opt, ModuleAndSymbolNamePatternsList &regexList) {
        if (!opt.empty()) {
            std::ifstream ifs(opt);
            
            if (!ifs) {
                std::stringstream ss;
                ss << "Specified patterns list file " << opt << " not found." << std::endl;
                throw std::invalid_argument(ss.str());
            }
            
            std::string line;
            while (std::getline(ifs, line)) {
                if (line.size() && strncmp(line.c_str(), "#", 1) != 0 && strncmp(line.c_str(), "//", 2) != 0) { // ignore comments and empty lines
                    std::size_t colon = line.find(':');
                    std::string modulePattern = line.substr(0, colon);
                    std::string symbolPattern = colon != std::string::npos ? line.substr(colon+1) : std::string();
                    regexList.push_back({ modulePattern, symbolPattern });
                }
            }
        }
    }

    bool _whitelistDefined = false;
    ModuleAndSymbolNamePatternsList _whitelist;
    ModuleAndSymbolNamePatternsList _blacklist;
};

} // namespace Meta

#endif /* ModulesBlacklist_h */
