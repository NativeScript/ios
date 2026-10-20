set(SWIFT_GENERATOR_SOURCES
    ${CMAKE_SOURCE_DIR}/src/Swift/CapabilityClassifier.cpp
    ${CMAKE_SOURCE_DIR}/src/Swift/CoverageReport.cpp
    ${CMAKE_SOURCE_DIR}/src/Swift/FragmentTokens.cpp
    ${CMAKE_SOURCE_DIR}/src/Swift/ProbeEmitter.cpp
    ${CMAKE_SOURCE_DIR}/src/Swift/ProbeVerifier.cpp
    ${CMAKE_SOURCE_DIR}/src/Swift/SwiftIR.cpp
    ${CMAKE_SOURCE_DIR}/src/Swift/SwiftSource.cpp
    ${CMAKE_SOURCE_DIR}/src/Swift/SwiftTypes.cpp
    ${CMAKE_SOURCE_DIR}/src/Swift/SymbolGraphLoader.cpp
    ${CMAKE_SOURCE_DIR}/src/TypeScript/SwiftDefinitionWriter.cpp
)

add_executable(swift-symbolgraph-tests
    swift/TestMain.cpp
    swift/SymbolGraphLoaderTests.cpp
    swift/SwiftTypesTests.cpp
    swift/ClassifierTests.cpp
    ${SWIFT_GENERATOR_SOURCES}
)
target_include_directories(swift-symbolgraph-tests PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_definitions(swift-symbolgraph-tests PRIVATE
    SWIFT_FIXTURE_DIR="${CMAKE_SOURCE_DIR}/TestFixtures/SwiftDemo"
    SWIFT_FIXTURE_GRAPHS_DIR="${CMAKE_SOURCE_DIR}/TestFixtures/SwiftDemo/symbolgraphs"
    SWIFT_SNAPSHOT_DIR="${CMAKE_CURRENT_SOURCE_DIR}/swift/snapshots"
)
target_link_libraries(swift-symbolgraph-tests ${LLVM_LINKER_FLAGS})
set_target_properties(swift-symbolgraph-tests PROPERTIES
    COMPILE_FLAGS "-Werror -Wall -Wextra -Wno-unused-parameter"
)

add_test(NAME swift-symbolgraph-tests COMMAND swift-symbolgraph-tests)
