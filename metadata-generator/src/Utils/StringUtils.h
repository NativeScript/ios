//
// Created by Yavor Georgiev on 14.01.16 г..
//

#pragma once

#include <algorithm>
#include <sstream>
#include <string>

namespace StringUtils {
template <class OutputIterator, typename CharT>
size_t split(const std::basic_string<CharT>& input, CharT delim, OutputIterator output)
{
    size_t count = 0;
    std::basic_stringstream<CharT> ss(input);
    std::basic_string<CharT> item;
    while (std::getline(ss, item, delim)) {
        if (item.size() == 0) {
            continue;
        }

        *(output++) = item;
        count++;
    }

    return count;
};

template <typename CharT>
bool starts_with(const std::basic_string<CharT>& string, const std::basic_string<CharT>& prefix)
{
    if (string.length() < prefix.length()) {
        return false;
    }

    return std::mismatch(prefix.begin(), prefix.end(), string.begin()).first == prefix.end();
}
}