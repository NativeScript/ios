add_executable(swift-symbolgraph-tests
    swift/SymbolGraphLoaderTests.cpp
    ${CMAKE_SOURCE_DIR}/src/Swift/SwiftIR.cpp
    ${CMAKE_SOURCE_DIR}/src/Swift/SymbolGraphLoader.cpp
    ${CMAKE_SOURCE_DIR}/src/TypeScript/SwiftDefinitionWriter.cpp
)
target_include_directories(swift-symbolgraph-tests PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_definitions(swift-symbolgraph-tests PRIVATE
    SWIFT_FIXTURE_GRAPHS_DIR="${CMAKE_SOURCE_DIR}/TestFixtures/SwiftDemo/symbolgraphs"
    SWIFT_SNAPSHOT_DIR="${CMAKE_CURRENT_SOURCE_DIR}/swift/snapshots"
)
target_link_libraries(swift-symbolgraph-tests ${LLVM_LINKER_FLAGS})
set_target_properties(swift-symbolgraph-tests PROPERTIES
    COMPILE_FLAGS "-Werror -Wall -Wextra -Wno-unused-parameter"
)

add_test(NAME swift-symbolgraph-tests COMMAND swift-symbolgraph-tests)
