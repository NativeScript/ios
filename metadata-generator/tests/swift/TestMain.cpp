#include "TestHarness.h"

int main(int argc, char** argv) {
  return TestHarness::runAll(argc > 1 ? argv[1] : "");
}
