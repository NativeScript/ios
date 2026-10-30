#ifndef LogChunks_h
#define LogChunks_h

#include <cstddef>
#include <string_view>

namespace tns {

// os_log replaces whatever exceeds its buffer with "<…>". The buffer also holds
// a few bytes of bookkeeping per argument, which left 996 bytes of text with two
// arguments on iPadOS 26.7, so stay well below that.
constexpr size_t kMaxLogChunkBytes = 900;

// How a chunk connects to the one after it.
enum class LogChunkBreak { kNone, kJoin, kLine };

// Invisible, so that the chunks read normally wherever they are not stitched.
// Control characters would not do: os_log escapes them.
constexpr const char* kLogChunkJoinMarker = "\u2060";
constexpr const char* kLogChunkLineMarker = "\u2061";

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

}  // namespace tns

#endif /* LogChunks_h */
