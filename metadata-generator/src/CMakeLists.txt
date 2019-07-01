set(GENERATOR_HEADERS
    Binary/binaryHashtable.h
    Binary/binaryOperation.h
    Binary/binaryReader.h
    Binary/binarySerializer.h
    Binary/binarySerializerPrivate.h
    Binary/binaryStructures.h
    Binary/binaryTypeEncodingSerializer.h
    Binary/binaryWriter.h
    Binary/metaFile.h
    HeadersParser/Parser.h
    Meta/CreationException.h
    Meta/DeclarationConverterVisitor.h
    Meta/Filters/HandleExceptionalMetasFilter.h
    Meta/Filters/HandleMethodsAndPropertiesWithSameNameFilter.h
    Meta/Filters/MergeCategoriesFilter.h
    Meta/Filters/RemoveDuplicateMembersFilter.h
    Meta/Filters/ResolveGlobalNamesCollisionsFilter.h
    Meta/MetaEntities.h
    Meta/MetaFactory.h
    Meta/MetaVisitor.h
    Meta/NameRetrieverVisitor.h
    Meta/TypeEntities.h
    Meta/TypeFactory.h
    Meta/TypeVisitor.h
    Meta/Utils.h
    Meta/ValidateMetaTypeVisitor.h
    TypeScript/DefinitionWriter.h
    TypeScript/DocSetManager.h
    Utils/fileStream.h
    Utils/memoryStream.h
    Utils/Noncopyable.h
    Utils/stream.h
    Utils/StringHasher.h
    Utils/StringUtils.h
    Yaml/MetaYamlTraits.h
    Yaml/YamlSerializer.h
)

set(GENERATOR_SOURCES
    Binary/binaryHashtable.cpp
    Binary/binaryReader.cpp
    Binary/binarySerializer.cpp
    Binary/binaryStructures.cpp
    Binary/binaryTypeEncodingSerializer.cpp
    Binary/binaryWriter.cpp
    Binary/metaFile.cpp
    HeadersParser/Parser.cpp
    main.cpp
    Meta/DeclarationConverterVisitor.cpp
    Meta/Filters/HandleExceptionalMetasFilter.cpp
    Meta/Filters/HandleMethodsAndPropertiesWithSameNameFilter.cpp
    Meta/Filters/MergeCategoriesFilter.cpp
    Meta/Filters/RemoveDuplicateMembersFilter.cpp
    Meta/Filters/ResolveGlobalNamesCollisionsFilter.cpp
    Meta/MetaEntities.cpp
    Meta/MetaFactory.cpp
    Meta/NameRetrieverVisitor.cpp
    Meta/TypeFactory.cpp
    Meta/Utils.cpp
    Meta/ValidateMetaTypeVisitor.cpp
    TypeScript/DefinitionWriter.cpp
    TypeScript/DocSetManager.cpp
    Utils/fileStream.cpp
    Utils/memoryStream.cpp
)

include_directories(${CMAKE_CURRENT_SOURCE_DIR} ${LIBXML2_INCLUDE_DIR})

add_executable(objc-metadata-generator ${GENERATOR_HEADERS} ${GENERATOR_SOURCES})
target_link_libraries(objc-metadata-generator
    ${LLVM_LINKER_FLAGS}
    ${LIBXML2_LIBRARIES}
    clangFrontend
    clangSerialization
    clangDriver
    clangParse
    clangSema
    clangAnalysis
    clangAST
    clangBasic
    clangEdit
    clangLex
    clangTooling
)

set_target_properties(objc-metadata-generator PROPERTIES
    COMPILE_FLAGS "-fvisibility=hidden -Werror -Wall -Wextra -Wno-unused-parameter"
)

add_custom_command(TARGET objc-metadata-generator
                   POST_BUILD
                   COMMAND ${CMAKE_COMMAND} -E copy_directory ${LLVM_LIBDIR}/clang ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/clang)

add_custom_command(TARGET objc-metadata-generator
                   POST_BUILD
                   COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/clang/*/lib)

install(TARGETS objc-metadata-generator
        RUNTIME DESTINATION bin)

install(DIRECTORY ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/clang DESTINATION bin/lib)

get_target_property(_target_sources objc-metadata-generator SOURCES)
foreach(child ${_target_sources})
    get_filename_component(child_directory ${child} DIRECTORY)
    string(REPLACE "/" "\\" groupName "${child_directory}")
    source_group("${groupName}" FILES ${child})
endforeach()
