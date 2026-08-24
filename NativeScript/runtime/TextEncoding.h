#ifndef TextEncoding_h
#define TextEncoding_h

#include "Common.h"

namespace tns {

// Native ops behind the text-encoding builtin (internal/text-encoding.js):
// the WHATWG label table, UTF-8 encoding and the decoders for the encodings
// the runtime supports (utf-8, utf-16le, utf-16be, windows-1252). The builtin
// owns the web-facing shapes; everything that touches bytes lives here.
class TextEncoding {
 public:
  static v8::Local<v8::Object> CreateBinding(v8::Local<v8::Context> context);

  // Bytes of decoder state the builtin must hand back on every decode call.
  static constexpr int kDecoderStateSize = 16;
};

}  // namespace tns

#endif /* TextEncoding_h */
