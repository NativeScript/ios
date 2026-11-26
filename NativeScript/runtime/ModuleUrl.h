#pragma once

#include <string>

namespace tns {

// Whether `key` is spelled the way the loader keys an HTTP module: a lowercase
// `http://` or `https://` prefix, file modules being keyed by absolute paths.
// Deliberately not a URL parse: it gates the rule that an HTTP importer never
// reaches the filesystem implicitly, so a key the URL parser would reject (an
// IPv6 zone id, say) must still count as HTTP.
bool IsHttpRegistryKey(const std::string& key);

struct ModuleUrl {
  bool parsed = false;
  bool http = false;  // the scheme is http or https
  std::string href;
};

// `input` parsed with the WHATWG URL parser (the one behind JS `new URL()`):
// as an absolute URL when `base` is empty, otherwise as a path- or
// scheme-relative reference against `base`.
//
// An http(s) result keeps its authority as written by whichever string
// supplied it: tooling compares module URLs against the origin string it was
// configured with, so that spelling is part of a module's identity. The
// parser's own href is used whenever the written authority would not name the
// same URL.
ModuleUrl ParseModuleUrl(const std::string& input, const std::string& base);

// The spelling the loader gives `input` as an absolute http(s) module URL:
// ParseModuleUrl's href; `input` itself when the parser rejects it but it is
// spelled as an HTTP key (fail closed: it stays HTTP); empty when `input` is
// not an http(s) URL.
std::string NormalizeHttpModuleUrl(const std::string& input);

}  // namespace tns
