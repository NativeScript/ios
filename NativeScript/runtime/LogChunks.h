#ifndef LogChunks_h
#define LogChunks_h

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>

namespace tns {

// os_log replaces whatever exceeds its buffer with "<…>". The buffer also holds
// a few bytes of bookkeeping per argument, which left 996 bytes of text with two
// arguments on iPadOS 26.7, so stay well below that.
constexpr size_t kMaxLogChunkBytes = 900;

// How a chunk connects to the one after it.
enum class LogChunkBreak { kNone, kJoin, kLine };

// Calls emit with consecutive pieces of message, each at most maxBytes long and
// never ending inside a UTF-8 sequence. A piece ends at the last line break that
// fits, so that lines stay intact whenever they can; that line break is dropped,
// since every piece is logged as a line of its own.
template <typename Emit>
void ForEachLogChunk(std::string_view message, size_t maxBytes, Emit&& emit) {
  while (message.size() > maxBytes) {
    size_t end = message.rfind('\n', maxBytes);
    size_t next = end + 1;
    LogChunkBreak chunkBreak = LogChunkBreak::kLine;

    if (end == std::string_view::npos || end == 0) {
      end = maxBytes;
      while (end > 0 && (static_cast<unsigned char>(message[end]) & 0xC0) == 0x80) {
        end--;
      }
      // Not UTF-8 at all: any cut is as good as another.
      if (end == 0) {
        end = maxBytes;
      }
      next = end;
      chunkBreak = LogChunkBreak::kJoin;
    }

    emit(message.substr(0, end), chunkBreak);
    message.remove_prefix(next);
  }

  emit(message, LogChunkBreak::kNone);
}

// The newest value of the logFormat key in the app's package.json that the
// runtime understands. The CLI writes the newest one it understands.
//
// Format 1 logs each piece of a split message as "[ns <id> <index>/<count>] "
// followed by the piece. <id> is unique per message in the process (hex) and
// <index> counts from 1. The pieces are consecutive slices of the message and
// only the first carries the message's prefix, so they join back into the
// message as they are. Messages that fit in one entry are logged without a
// header.
constexpr int kNewestLogFormat = 1;

// Room for the longest header: ids up to 8 hex digits and counts up to 7
// decimal ones (messages of several GB).
constexpr size_t kMaxLogChunkHeaderBytes = 40;

inline std::string_view FormatLogChunkHeader(char (&buffer)[kMaxLogChunkHeaderBytes], uint32_t id,
                                             size_t index, size_t count) {
  int length = snprintf(buffer, sizeof(buffer), "[ns %x %zu/%zu] ", id, index, count);
  if (length < 0) {
    return {};
  }
  return std::string_view(buffer, static_cast<size_t>(length) < sizeof(buffer)
                                      ? static_cast<size_t>(length)
                                      : sizeof(buffer) - 1);
}

inline bool IsLogWhitespace(char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

// Calls emit with consecutive slices of text, each at most maxBytes long and
// never ending inside a UTF-8 sequence. The unified log strips whitespace from
// the end of every entry, so a slice never ends in whitespace: it is left for
// the start of the next slice, behind that slice's header. Only a run of
// whitespace longer than maxBytes still loses what it ends with. A slice ends
// before the last line break that fits, so that lines stay intact whenever they
// can.
template <typename Emit>
void ForEachLogSlice(std::string_view text, size_t maxBytes, Emit&& emit) {
  auto backOverWhitespace = [&](size_t end) {
    while (end > 0 && IsLogWhitespace(text[end - 1])) {
      end--;
    }
    return end;
  };

  while (text.size() > maxBytes) {
    size_t lineBreak = text.rfind('\n', maxBytes);
    size_t end = lineBreak == std::string_view::npos ? 0 : backOverWhitespace(lineBreak);

    if (end == 0) {
      end = maxBytes;
      while (end > 0 && (static_cast<unsigned char>(text[end]) & 0xC0) == 0x80) {
        end--;
      }
      // Not UTF-8 at all: any cut is as good as another.
      if (end == 0) {
        end = maxBytes;
      }
      if (size_t beforeWhitespace = backOverWhitespace(end)) {
        end = beforeWhitespace;
      }
    }

    emit(text.substr(0, end));
    text.remove_prefix(end);
  }

  emit(text);
}

// Calls emit with the header and text of each piece of prefix + message, split
// in format 1 as the message with the given id.
template <typename Emit>
void ForEachFramedLogChunk(std::string_view prefix, std::string_view message, uint32_t id,
                           Emit&& emit) {
  std::string text;
  text.reserve(prefix.size() + message.size());
  text.append(prefix).append(message);

  std::vector<std::string_view> pieces;
  ForEachLogSlice(text, kMaxLogChunkBytes - kMaxLogChunkHeaderBytes,
                  [&](std::string_view piece) { pieces.push_back(piece); });

  for (size_t i = 0; i < pieces.size(); i++) {
    char buffer[kMaxLogChunkHeaderBytes];
    emit(FormatLogChunkHeader(buffer, id, i + 1, pieces.size()), pieces[i]);
  }
}

}  // namespace tns

#endif /* LogChunks_h */
