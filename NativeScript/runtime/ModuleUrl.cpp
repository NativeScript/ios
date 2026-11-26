#include "ModuleUrl.h"

#include <string_view>

#include "ada/ada.h"

namespace tns {

namespace {

bool StartsWith(const std::string& s, const char* prefix) {
  const size_t n = std::char_traits<char>::length(prefix);
  return s.size() >= n && s.compare(0, n, prefix) == 0;
}

bool HasHttpScheme(const ada::url_aggregator& url) {
  return url.type == ada::scheme::type::HTTP ||
         url.type == ada::scheme::type::HTTPS;
}

// The authority (userinfo, host, port) of an absolute or scheme-relative URL
// exactly as written, or empty when `url` does not spell one plainly.
std::string WrittenAuthority(const std::string& url) {
  size_t start = 0;
  if (StartsWith(url, "//")) {
    start = 2;
  } else {
    const size_t colon = url.find(':');
    if (colon == std::string::npos || url.compare(colon, 3, "://") != 0) {
      return std::string();
    }
    start = colon + 3;
  }
  const size_t end = url.find_first_of("/?#", start);
  std::string authority =
      url.substr(start, end == std::string::npos ? end : end - start);
  for (const char c : authority) {
    if (static_cast<unsigned char>(c) <= 0x20 || c == '\\') {
      return std::string();
    }
  }
  return authority;
}

}  // namespace

bool IsHttpRegistryKey(const std::string& key) {
  if (key.compare(0, 4, "http") != 0) {
    return false;
  }
  const size_t schemeEnd = key.size() > 4 && key[4] == 's' ? 5 : 4;
  return key.compare(schemeEnd, 3, "://") == 0;
}

ModuleUrl ParseModuleUrl(const std::string& input, const std::string& base) {
  ModuleUrl result;
  ada::result<ada::url_aggregator> url;
  if (base.empty()) {
    url = ada::parse<ada::url_aggregator>(input, nullptr);
  } else {
    auto baseUrl = ada::parse<ada::url_aggregator>(base, nullptr);
    if (!baseUrl) {
      return result;
    }
    url = ada::parse<ada::url_aggregator>(input, &baseUrl.value());
  }
  if (!url) {
    return result;
  }
  result.parsed = true;
  result.http = HasHttpScheme(*url);
  result.href = std::string(url->get_href());
  if (!result.http) {
    return result;
  }

  const std::string authority =
      WrittenAuthority(base.empty() || StartsWith(input, "//") ? input : base);
  if (authority.empty()) {
    return result;
  }
  // Everything after the authority comes from the parser's own href: its
  // getters drop an empty query's '?' and an empty fragment's '#'.
  const std::string_view href = url->get_href();
  const std::string written =
      std::string(url->get_protocol()) + "//" + authority +
      std::string(href.substr(url->get_components().pathname_start));
  auto reparsed = ada::parse<ada::url_aggregator>(written, nullptr);
  if (reparsed && reparsed->get_href() == href) {
    result.href = written;
  }
  return result;
}

std::string NormalizeHttpModuleUrl(const std::string& input) {
  const ModuleUrl url = ParseModuleUrl(input, std::string());
  if (url.parsed) {
    return url.http ? url.href : std::string();
  }
  return IsHttpRegistryKey(input) ? input : std::string();
}

}  // namespace tns
