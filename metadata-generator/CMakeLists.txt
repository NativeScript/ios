project(MetadataGenerator)
cmake_minimum_required(VERSION 2.8)

#set(CMAKE_VERBOSE_MAKEFILE ON)

IF(NOT DEFINED METADATA_BINARY_ARCH)
    set(METADATA_BINARY_ARCH "${CMAKE_HOST_SYSTEM_PROCESSOR}")
ENDIF(NOT DEFINED METADATA_BINARY_ARCH)

find_package(LibXml2)
if (NOT LIBXML2_FOUND)
    message(FATAL_ERROR "libXML2 not found")
endif ()

get_filename_component(LLVM_ROOT "../../llvm/8.0.0" REALPATH BASE_DIR "${CMAKE_BINARY_DIR}")
set(CMAKE_OSX_DEPLOYMENT_TARGET 10.12)

set(LLVM_SYSTEM_LIBS "-lz -lcurses -lm -lxml2")
set(LLVM_PREPROCESSOR_FLAGS "-I${LLVM_ROOT}/include -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS")
set(LLVM_LIBS "-lLLVMLTO -lLLVMPasses -lLLVMObjCARCOpts -lLLVMMIRParser -lLLVMSymbolize -lLLVMDebugInfoPDB -lLLVMDebugInfoDWARF -lLLVMCoverage -lLLVMMCA -lLLVMTableGen -lLLVMDlltoolDriver -lLLVMXRay -lLLVMOrcJIT -lLLVMXCoreDisassembler -lLLVMXCoreCodeGen -lLLVMXCoreDesc -lLLVMXCoreInfo -lLLVMXCoreAsmPrinter -lLLVMWebAssemblyDisassembler -lLLVMWebAssemblyCodeGen -lLLVMWebAssemblyDesc -lLLVMWebAssemblyAsmPrinter -lLLVMWebAssemblyAsmParser -lLLVMWebAssemblyInfo -lLLVMSystemZDisassembler -lLLVMSystemZCodeGen -lLLVMSystemZAsmParser -lLLVMSystemZDesc -lLLVMSystemZInfo -lLLVMSystemZAsmPrinter -lLLVMSparcDisassembler -lLLVMSparcCodeGen -lLLVMSparcAsmParser -lLLVMSparcDesc -lLLVMSparcInfo -lLLVMSparcAsmPrinter -lLLVMPowerPCDisassembler -lLLVMPowerPCCodeGen -lLLVMPowerPCAsmParser -lLLVMPowerPCDesc -lLLVMPowerPCInfo -lLLVMPowerPCAsmPrinter -lLLVMNVPTXCodeGen -lLLVMNVPTXDesc -lLLVMNVPTXInfo -lLLVMNVPTXAsmPrinter -lLLVMMSP430Disassembler -lLLVMMSP430CodeGen -lLLVMMSP430AsmParser -lLLVMMSP430Desc -lLLVMMSP430Info -lLLVMMSP430AsmPrinter -lLLVMMipsDisassembler -lLLVMMipsCodeGen -lLLVMMipsAsmParser -lLLVMMipsDesc -lLLVMMipsInfo -lLLVMMipsAsmPrinter -lLLVMLanaiDisassembler -lLLVMLanaiCodeGen -lLLVMLanaiAsmParser -lLLVMLanaiDesc -lLLVMLanaiAsmPrinter -lLLVMLanaiInfo -lLLVMHexagonDisassembler -lLLVMHexagonCodeGen -lLLVMHexagonAsmParser -lLLVMHexagonDesc -lLLVMHexagonInfo -lLLVMBPFDisassembler -lLLVMBPFCodeGen -lLLVMBPFAsmParser -lLLVMBPFDesc -lLLVMBPFInfo -lLLVMBPFAsmPrinter -lLLVMARMDisassembler -lLLVMARMCodeGen -lLLVMARMAsmParser -lLLVMARMDesc -lLLVMARMInfo -lLLVMARMAsmPrinter -lLLVMARMUtils -lLLVMAMDGPUDisassembler -lLLVMAMDGPUCodeGen -lLLVMAMDGPUAsmParser -lLLVMAMDGPUDesc -lLLVMAMDGPUInfo -lLLVMAMDGPUAsmPrinter -lLLVMAMDGPUUtils -lLLVMAArch64Disassembler -lLLVMAArch64CodeGen -lLLVMAArch64AsmParser -lLLVMAArch64Desc -lLLVMAArch64Info -lLLVMAArch64AsmPrinter -lLLVMAArch64Utils -lLLVMObjectYAML -lLLVMLibDriver -lLLVMOption -lLLVMOptRemarks -lLLVMWindowsManifest -lLLVMTextAPI -lLLVMFuzzMutate -lLLVMX86Disassembler -lLLVMX86AsmParser -lLLVMX86CodeGen -lLLVMGlobalISel -lLLVMSelectionDAG -lLLVMAsmPrinter -lLLVMX86Desc -lLLVMMCDisassembler -lLLVMX86Info -lLLVMX86AsmPrinter -lLLVMX86Utils -lLLVMMCJIT -lLLVMLineEditor -lLLVMInterpreter -lLLVMExecutionEngine -lLLVMRuntimeDyld -lLLVMCodeGen -lLLVMTarget -lLLVMCoroutines -lLLVMipo -lLLVMInstrumentation -lLLVMVectorize -lLLVMScalarOpts -lLLVMLinker -lLLVMIRReader -lLLVMAsmParser -lLLVMInstCombine -lLLVMBitWriter -lLLVMAggressiveInstCombine -lLLVMTransformUtils -lLLVMAnalysis -lLLVMProfileData -lLLVMObject -lLLVMMCParser -lLLVMMC -lLLVMDebugInfoCodeView -lLLVMDebugInfoMSF -lLLVMBitReader -lLLVMCore -lLLVMBinaryFormat -lLLVMSupport -lLLVMDemangle")
set(LLVM_LIBDIR "${LLVM_ROOT}/lib_${METADATA_BINARY_ARCH}")
set(LLVM_LINKER_FLAGS "-L${LLVM_LIBDIR} -Wl,-search_paths_first -Wl,-headerpad_max_install_names")

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -target ${METADATA_BINARY_ARCH}-apple-darwin -std=c++11 -fno-rtti ${LLVM_PREPROCESSOR_FLAGS}")
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
