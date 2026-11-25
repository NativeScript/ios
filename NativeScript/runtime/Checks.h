#ifndef Checks_h
#define Checks_h

#include <string>

// How runtime code handles a failed condition:
//
// - A condition JS can reach throws a JS error: a TypeError for a bad
//   argument or receiver, or the exception a failed V8 call left pending.
// - A failed v8::Maybe / MaybeLocal call propagates its pending exception.
// - NS_CHECK(cond, message): an invariant whose violation makes continuing
//   unsafe. On in every build.
// - NS_DCHECK(cond) / NS_DCHECK_MSG(cond, message): a cheap internal sanity
//   check, on only while NS_DCHECK_IS_ON. It is the one intentional
//   Debug/Release difference, so it never guards anything JS can reach.
// - NS_UNREACHABLE(message): a branch that cannot be taken.
// - tns::Assert is legacy: a call site moves to the above when its code is
//   touched.
//
// All of them end in tns::Fatal, which logs the location, the message, the
// native backtrace and, when an isolate is entered on the calling thread, the
// JS stack, then aborts.
//
// The names are prefixed: the vendored V8 inspector headers and the Node-API
// shim define their own unprefixed CHECK/DCHECK.

namespace tns {

[[noreturn]] void Fatal(const char* location, const std::string& message);

}  // namespace tns

#define NS_CHECKS_STRINGIFY_HELPER(x) #x
#define NS_CHECKS_STRINGIFY(x) NS_CHECKS_STRINGIFY_HELPER(x)
#define NS_CHECKS_LOCATION __FILE__ ":" NS_CHECKS_STRINGIFY(__LINE__)

#ifndef NS_DCHECK_IS_ON
#if defined(DEBUG)
#define NS_DCHECK_IS_ON 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define NS_DCHECK_IS_ON 1
#else
#define NS_DCHECK_IS_ON 0
#endif
#else
#define NS_DCHECK_IS_ON 0
#endif
#endif

#define NS_CHECK(cond, message)                                              \
  do {                                                                       \
    if (!(cond)) [[unlikely]] {                                              \
      ::tns::Fatal(NS_CHECKS_LOCATION,                                       \
                   std::string("NS_CHECK(" #cond ") failed: ") + (message)); \
    }                                                                        \
  } while (0)

#if NS_DCHECK_IS_ON
#define NS_DCHECK(cond)                                                \
  do {                                                                 \
    if (!(cond)) [[unlikely]] {                                        \
      ::tns::Fatal(NS_CHECKS_LOCATION, "NS_DCHECK(" #cond ") failed"); \
    }                                                                  \
  } while (0)
#define NS_DCHECK_MSG(cond, message)                                          \
  do {                                                                        \
    if (!(cond)) [[unlikely]] {                                               \
      ::tns::Fatal(NS_CHECKS_LOCATION,                                        \
                   std::string("NS_DCHECK(" #cond ") failed: ") + (message)); \
    }                                                                         \
  } while (0)
#else
// Never evaluated, but still compiled, so names used only here stay used.
#define NS_DCHECK(cond) \
  do {                  \
    if (false) {        \
      (void)(cond);     \
    }                   \
  } while (0)
#define NS_DCHECK_MSG(cond, message) \
  do {                               \
    if (false) {                     \
      (void)(cond);                  \
      (void)(message);               \
    }                                \
  } while (0)
#endif

#define NS_UNREACHABLE(message) \
  ::tns::Fatal(NS_CHECKS_LOCATION, std::string("NS_UNREACHABLE: ") + (message))

#endif /* Checks_h */
