#include "system_idna.h"

#if NS_ADA_SYSTEM_IDNA
#include <unicode/uchar.h>
#include <unicode/uidna.h>

// Autolinks libicucore so that turning the flag on is the only switch.
__asm__(".linker_option \"-licucore\"");

namespace tns {

static const UIDNA* Uts46() {
  static const UIDNA* idna = [] {
    UErrorCode err = U_ZERO_ERROR;
    // Explicit nontransitional bits: UIDNA_DEFAULT changed meaning in ICU 76.
    return uidna_openUTS46(UIDNA_CHECK_BIDI | UIDNA_CHECK_CONTEXTJ |
                               UIDNA_NONTRANSITIONAL_TO_ASCII |
                               UIDNA_NONTRANSITIONAL_TO_UNICODE,
                           &err);
  }();
  return idna;
}

std::string SystemIdnaToAscii(std::string_view input) {
  // WHATWG "domain to ASCII" with beStrict=false lowercases an all-ASCII
  // domain whatever ToASCII would say; ICU rejects e.g. invalid "xn--" labels.
  bool ascii = true;
  for (unsigned char c : input) {
    ascii &= c < 0x80;
  }
  if (ascii) {
    std::string lower(input);
    for (char& c : lower) {
      if (c >= 'A' && c <= 'Z') {
        c += 'a' - 'A';
      }
    }
    return lower;
  }

  // CheckHyphens and VerifyDnsLength are off for URLs, and ICU has no options
  // for them, so their errors are not failures.
  constexpr uint32_t kIgnoredErrors =
      UIDNA_ERROR_EMPTY_LABEL | UIDNA_ERROR_LABEL_TOO_LONG |
      UIDNA_ERROR_DOMAIN_NAME_TOO_LONG | UIDNA_ERROR_LEADING_HYPHEN |
      UIDNA_ERROR_TRAILING_HYPHEN | UIDNA_ERROR_HYPHEN_3_4;

  const UIDNA* idna = Uts46();
  if (idna == nullptr) {
    return {};
  }
  std::string out(input.size() * 2 + 64, '\0');
  for (int attempt = 0; attempt < 2; attempt++) {
    UIDNAInfo info = UIDNA_INFO_INITIALIZER;
    UErrorCode err = U_ZERO_ERROR;
    int32_t length = uidna_nameToASCII_UTF8(
        idna, input.data(), static_cast<int32_t>(input.size()), out.data(),
        static_cast<int32_t>(out.size()), &info, &err);
    if (err == U_BUFFER_OVERFLOW_ERROR) {
      out.resize(length);
      continue;
    }
    if (U_FAILURE(err) || (info.errors & ~kIgnoredErrors) != 0 ||
        length == 0) {
      return {};
    }
    out.resize(length);
    return out;
  }
  return {};
}

bool SystemIsNameCodePoint(char32_t code_point, bool first) {
  return u_hasBinaryProperty(static_cast<UChar32>(code_point),
                             first ? UCHAR_ID_START : UCHAR_ID_CONTINUE);
}

}  // namespace tns
#endif
