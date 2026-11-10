cmake_minimum_required(VERSION 3.20)
project(MetadataGenerator)

#set(CMAKE_VERBOSE_MAKEFILE ON)

IF(NOT DEFINED METADATA_BINARY_ARCH)
    set(METADATA_BINARY_ARCH "${CMAKE_HOST_SYSTEM_PROCESSOR}")
ENDIF(NOT DEFINED METADATA_BINARY_ARCH)

find_package(LibXml2)
if (NOT LIBXML2_FOUND)
    message(FATAL_ERROR "libXML2 not found")
endif ()

get_filename_component(LLVM_ROOT "../../llvm/17.0.8" REALPATH BASE_DIR "${CMAKE_BINARY_DIR}")
set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0)

set(LLVM_SYSTEM_LIBS "-lz -lcurses -lm -lxml2")
set(LLVM_PREPROCESSOR_FLAGS "-isystem ${LLVM_ROOT}/include -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS")
# The static archives the generator links. It needs no LLVM backend:
# clang gets target information from clangBasic.
set(LLVM_LIBS
    clangTooling clangFrontend clangDriver clangSerialization clangParse clangSema
    clangAnalysis clangASTMatchers clangEdit clangAST clangLex clangAPINotes clangCAS
    clangSupport clangBasic
    LLVMFrontendOpenMP LLVMOption LLVMObject LLVMTextAPI LLVMIRReader LLVMAsmParser
    LLVMBitReader LLVMMCParser LLVMMC LLVMDebugInfoDWARF LLVMDebugInfoCodeView
    LLVMProfileData LLVMCore LLVMRemarks LLVMBitstreamReader LLVMBinaryFormat LLVMCAS
    LLVMTargetParser LLVMWindowsDriver LLVMSupport LLVMDemangle
)
list(TRANSFORM LLVM_LIBS PREPEND "-l")
list(JOIN LLVM_LIBS " " LLVM_LIBS)

set(LLVM_LIBDIR "${LLVM_ROOT}/lib_${METADATA_BINARY_ARCH}")
set(LLVM_LINKER_FLAGS "-L${LLVM_LIBDIR} -Wl,-search_paths_first -Wl,-headerpad_max_install_names -Wl,-dead_strip")

set(CMAKE_BUILD_TYPE Release)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -target ${METADATA_BINARY_ARCH}-apple-darwin -std=c++17 -fno-rtti ${LLVM_PREPROCESSOR_FLAGS}")

set(LLVM_LINKER_FLAGS "${LLVM_LINKER_FLAGS} ${LLVM_SYSTEM_LIBS} ${LLVM_LIBS}")

set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin/lib)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# Output executables in the bin/ directory (not in subdirs) because clang libs
# are hardcoded to search for their built-in headers in `./lib`
# Needed for successfully debugging the metadata generator from Xcode
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_DEBUG ${CMAKE_RUNTIME_OUTPUT_DIRECTORY})
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO ${CMAKE_RUNTIME_OUTPUT_DIRECTORY})
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL ${CMAKE_RUNTIME_OUTPUT_DIRECTORY})
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE ${CMAKE_RUNTIME_OUTPUT_DIRECTORY})

add_subdirectory(src)
# copy build-step-metadata-generator.py to the bin folder
configure_file(build-step-metadata-generator.py ${CMAKE_CURRENT_BINARY_DIR}/bin/build-step-metadata-generator.py COPYONLY)
