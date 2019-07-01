project(MetadataGenerator)
cmake_minimum_required(VERSION 2.8)

find_program(LLVM_CONFIG_EXE llvm-config HINTS ENV LLVM_CONFIG_PATH LLVM_CONFIG_PATH)
if (NOT EXISTS ${LLVM_CONFIG_EXE})
    message(FATAL_ERROR "llvm-config not found")
endif ()
macro(llvm_config option var)
    execute_process(
        COMMAND ${LLVM_CONFIG_EXE} --${option}
        OUTPUT_VARIABLE ${var}
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
endmacro()

find_package(LibXml2)
if (NOT LIBXML2_FOUND)
    message(FATAL_ERROR "libXML2 not found")
endif ()


set(CMAKE_OSX_DEPLOYMENT_TARGET 10.12)

llvm_config(system-libs LLVM_SYSTEM_LIBS)
llvm_config(cppflags LLVM_PREPROCESSOR_FLAGS)
llvm_config(libs LLVM_LIBS)
llvm_config(ldflags LLVM_LINKER_FLAGS)
llvm_config(libdir LLVM_LIBDIR)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++11 -fno-rtti ${LLVM_PREPROCESSOR_FLAGS}")
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
