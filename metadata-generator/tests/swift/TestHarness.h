#pragma once

#include <functional>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace TestHarness {

struct TestCase {
  const char* name;
  std::function<void()> body;
};

inline std::vector<TestCase>& registry() {
  static std::vector<TestCase> tests;
  return tests;
}

inline int& failureCount() {
  static int failures = 0;
  return failures;
}

struct Registrar {
  Registrar(const char* name, std::function<void()> body) {
    registry().push_back(TestCase{name, std::move(body)});
  }
};

inline void fail(const char* file, int line, const std::string& message) {
  failureCount()++;
  std::cerr << file << ":" << line << ": FAILED: " << message << std::endl;
}

// Runs every registered test whose name contains `filter`.
inline int runAll(const std::string& filter) {
  int ran = 0;
  for (const auto& test : registry()) {
    if (!filter.empty() &&
        std::string(test.name).find(filter) == std::string::npos) {
      continue;
    }
    int before = failureCount();
    test.body();
    ran++;
    std::cout << (failureCount() == before ? "[ OK ] " : "[FAIL] ") << test.name
              << std::endl;
  }
  std::cout << ran << " tests, " << failureCount() << " failed checks"
            << std::endl;
  return failureCount() == 0 && ran > 0 ? 0 : 1;
}

}  // namespace TestHarness

#define TEST_CONCAT_INNER(a, b) a##b
#define TEST_CONCAT(a, b) TEST_CONCAT_INNER(a, b)

#define TEST(name)                                             \
  static void TEST_CONCAT(test_, name)();                      \
  static TestHarness::Registrar TEST_CONCAT(registrar_, name)( \
      #name, TEST_CONCAT(test_, name));                        \
  static void TEST_CONCAT(test_, name)()

#define CHECK(condition)                                              \
  do {                                                                \
    if (!(condition)) {                                               \
      TestHarness::fail(__FILE__, __LINE__, "CHECK(" #condition ")"); \
    }                                                                 \
  } while (0)

#define CHECK_EQ(actual, expected)                          \
  do {                                                      \
    const auto& actualValue = (actual);                     \
    const auto& expectedValue = (expected);                 \
    if (!(actualValue == expectedValue)) {                  \
      std::ostringstream message;                           \
      message << #actual << " == " << #expected             \
              << "\n  actual:   " << actualValue            \
              << "\n  expected: " << expectedValue;         \
      TestHarness::fail(__FILE__, __LINE__, message.str()); \
    }                                                       \
  } while (0)

// Stops the current test when a precondition for later checks fails.
#define REQUIRE(condition)                                              \
  do {                                                                  \
    if (!(condition)) {                                                 \
      TestHarness::fail(__FILE__, __LINE__, "REQUIRE(" #condition ")"); \
      return;                                                           \
    }                                                                   \
  } while (0)
