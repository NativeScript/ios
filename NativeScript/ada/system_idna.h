#ifndef NS_ADA_SYSTEM_IDNA_H
#define NS_ADA_SYSTEM_IDNA_H

// 1: ada uses the system ICU (libicucore) for UTS #46 host conversion and for
// URLPattern's identifier code point check, so its own compressed Unicode
// tables dead-strip (~80 KB). Results follow the OS's Unicode data: iOS
// 13-17.3 ship ICU 64-72 (Unicode 12.1-15.0), which rejects newer characters
// and maps U+1E9E to "ss" where current UTS #46 keeps "ß".
//
// ada.cpp is vendored: after upgrading it, re-add the include of this header
// below `#include "ada.h"` and the NS_ADA_SYSTEM_IDNA branches in
// `ada::unicode::to_ascii` and `ada::idna::valid_name_code_point`. Both must
// be switched, or the tables stay linked.
#ifndef NS_ADA_SYSTEM_IDNA
#define NS_ADA_SYSTEM_IDNA 0
#endif

#if NS_ADA_SYSTEM_IDNA
#include <string>
#include <string_view>

namespace tns {

// Same contract as ada::idna::to_ascii: an empty string means failure.
__attribute__((visibility("hidden"))) std::string SystemIdnaToAscii(
    std::string_view input);

// The table lookup of ada::idna::valid_name_code_point: ID_Start when
// `first`, otherwise ID_Continue.
__attribute__((visibility("hidden"))) bool SystemIsNameCodePoint(
    char32_t code_point, bool first);

}  // namespace tns
#endif

#endif  // NS_ADA_SYSTEM_IDNA_H
