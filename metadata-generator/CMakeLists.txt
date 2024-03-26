cmake_minimum_required(VERSION 3.20)
project(MetadataGenerator)
include(CheckCCompilerFlag)

#set(CMAKE_VERBOSE_MAKEFILE ON)

IF(NOT DEFINED METADATA_BINARY_ARCH)
    set(METADATA_BINARY_ARCH "${CMAKE_HOST_SYSTEM_PROCESSOR}")
ENDIF(NOT DEFINED METADATA_BINARY_ARCH)

find_package(LibXml2)
if (NOT LIBXML2_FOUND)
    message(FATAL_ERROR "libXML2 not found")
endif ()

get_filename_component(LLVM_ROOT "../../llvm/15.0.7" REALPATH BASE_DIR "${CMAKE_BINARY_DIR}")
set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0)

set(LLVM_SYSTEM_LIBS "-lz -lcurses -lm -lxml2")
set(LLVM_PREPROCESSOR_FLAGS "-I${LLVM_ROOT}/include -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS")
# these are all available libs currently, we probably don't need all
#set(LLVM_LIBS "-lLLVMCFGuard  -lLLVMMipsInfo  -lclangFrontend  -lclangToolingRefactoring  -lLLVMGlobalISel  -lLLVMFileCheck  -lLLVMAnalysis  -lLLVMAArch64AsmParser  -lLLVMBPFAsmParser  -lclangToolingASTDiff  -lLLVMAArch64Utils  -lLLVMMCA  -lclangHandleLLVM  -lLLVMMIRParser  -lLLVMHexagonAsmParser  -lLLVMLanaiDesc  -lLLVMSparcDisassembler  -llldELF  -lLLVMMipsAsmParser  -lLLVMDebugInfoDWARF  -lLLVMAVRDisassembler  -lLLVMWebAssemblyInfo  -lLLVMHexagonInfo  -lLLVMARMCodeGen  -lLLVMPowerPCCodeGen  -lLLVMXRay  -lLLVMMSP430CodeGen  -lLLVMVectorize  -lLLVMHexagonCodeGen  -lclangCrossTU  -lLLVMSupport  -lLLVMDWP  -lLLVMWindowsManifest  -lclangToolingInclusions  -lLLVMNVPTXDesc  -lc++  -lLLVMXCoreCodeGen  -lLLVMSystemZInfo  -lclangFormat  -lLLVMWebAssemblyUtils  -lLLVMCFIVerify  -lLLVMXCoreInfo  -lLLVMAVRDesc  -lLLVMARMDisassembler  -lclangAPINotes  -lLLVMSparcDesc  -llldCOFF  -lLLVMAggressiveInstCombine  -lLLVMAMDGPUDesc  -lLLVMMSP430AsmParser  -lclangIndexSerialization  -lLLVMExtensions  -lLLVMInstCombine  -lLLVMDWARFLinker  -lclangHandleCXX  -lLLVMRISCVDisassembler  -lclangDependencyScanning  -lLLVMRISCVAsmParser  -lLLVMFuzzMutate  -lLLVMExegesisMips  -lclangDynamicASTMatchers  -lclangTransformer  -lclangCodeGen  -lLLVMScalarOpts  -lLLVMTextAPI  -lclangSerialization  -lLLVMPasses  -lLLVMBPFInfo  -lLLVMLinker  -lLLVMObject  -lLLVMMCJIT  -lPollyISL  -lLLVMExegesisPowerPC  -lLLVMCore  -lLLVMLanaiCodeGen  -lLLVMipo  -lLLVMAArch64Info  -lLLVMMC  -lLLVMObjCARCOpts  -lclangRewrite  -lLLVMCodeGen  -lclangAST  -lLLVMTarget  -lLLVMX86AsmParser  -lLLVMFrontendOpenACC  -llldYAML  -lLLVMDebugInfoPDB  -lLLVMMCDisassembler  -lclangEdit  -lLLVMX86CodeGen  -lLLVMX86Info  -lLLVMBPFCodeGen  -lLLVMDebugInfoGSYM  -lLLVMBPFDisassembler  -lclangRewriteFrontend  -lclangLex  -lLLVMRISCVInfo  -lLLVMJITLink  -lLLVMBitReader  -lLLVMHexagonDisassembler  -lLLVMExecutionEngine  -lLLVMMSP430Desc  -lLLVMPowerPCDesc  -llldCommon  -lLLVMWebAssemblyAsmParser  -lclangBasic  -lLLVMSystemZAsmParser  -lLLVMLTO  -lLLVMSystemZCodeGen  -lLLVMRemarks  -lLLVMOption  -lLLVMARMDesc  -lLLVMAMDGPUUtils  -lclangAnalysis  -lLLVMPowerPCAsmParser  -lLLVMOrcTargetProcess  -lLLVMInterfaceStub  -lclangStaticAnalyzerCore  -lclangASTMatchers  -lLLVMIRReader  -llldWasm  -lLLVMFrontendOpenMP  -llldDriver  -lLLVMAArch64Desc  -lclangDirectoryWatcher  -lLLVMAVRCodeGen  -lLLVMWebAssemblyDisassembler  -lLLVMLanaiAsmParser  -lLLVMRISCVCodeGen  -lLLVMBPFDesc  -lLLVMMSP430Disassembler  -lclangDriver  -lLLVMTransformUtils  -lLLVMLibDriver  -lLLVMCoverage  -lLLVMARMInfo  -lLLVMExegesisAArch64  -lclangParse  -lLLVMInterpreter  -lLLVMPowerPCInfo  -lLLVMRuntimeDyld  -lLLVMMSP430Info  -lLLVMProfileData  -lLLVMSymbolize  -lLLVMSelectionDAG  -lLLVMRISCVDesc  -lLLVMExegesisX86  -lLLVMX86Desc  -lLLVMSparcCodeGen  -lLLVMBitWriter  -lclangStaticAnalyzerCheckers  -lLLVMObjectYAML  -lclangTooling  -lLLVMBinaryFormat  -lLLVMMCParser  -lLLVMWebAssemblyDesc  -lLLVMHexagonDesc  -lLLVMAMDGPUCodeGen  -lLLVMX86Disassembler  -lclangToolingCore  -lLLVMDemangle  -lLLVMARMAsmParser  -lLLVMLanaiDisassembler  -lLLVMLineEditor  -lLLVMMipsCodeGen  -lclangTesting  -lLLVMLanaiInfo  -lLLVMOrcJIT  -lclangInterpreter  -llldReaderWriter  -lLLVMAsmPrinter  -lLLVMExegesis  -lLLVMAArch64Disassembler  -lLLVMTableGenGlobalISel  -lclangToolingSyntax  -lLLVMMipsDesc  -lPolly  -lLLVMMCACustomBehaviourAMDGPU  -llldMinGW  -lLLVMXCoreDisassembler  -lLLVMTableGen  -lLLVMAArch64CodeGen  -llldMachO  -lLLVMCoroutines  -llldMachO2  -lLLVMAVRAsmParser  -lLLVMPowerPCDisassembler  -lLLVMDebugInfoCodeView  -lLLVMNVPTXCodeGen  -lclangFrontendTool  -lLLVMAMDGPUInfo  -llldCore  -lLLVMWebAssemblyCodeGen  -lLLVMSystemZDisassembler  -lLLVMSparcInfo  -lLLVMAMDGPUDisassembler  -lLLVMAVRInfo  -lclangARCMigrate  -lLLVMSparcAsmParser  -lLLVMXCoreDesc  -lLLVMAsmParser  -lLLVMDebugInfoMSF  -lLLVMOrcShared  -lLLVMSystemZDesc  -lLLVMNVPTXInfo  -lLLVMBitstreamReader  -lclangStaticAnalyzerFrontend  -lclangIndex  -lLLVMInstrumentation  -lclangSema  -lLLVMDlltoolDriver  -lLLVMARMUtils  -lLLVMMipsDisassembler  -lLLVMAMDGPUAsmParser")
# these come from the older llvm plus some added ones at the end
set(LLVM_LIBS "-lLLVMLTO -lLLVMPasses -lLLVMObjCARCOpts -lLLVMMIRParser -lLLVMSymbolize -lLLVMDebugInfoPDB -lLLVMDebugInfoDWARF -lLLVMCoverage -lLLVMMCA -lLLVMTableGen -lLLVMDlltoolDriver -lLLVMXRay -lLLVMOrcJIT -lLLVMXCoreDisassembler -lLLVMXCoreCodeGen -lLLVMXCoreDesc -lLLVMXCoreInfo -lLLVMWebAssemblyDisassembler -lLLVMWebAssemblyCodeGen -lLLVMWebAssemblyDesc -lLLVMWebAssemblyAsmParser -lLLVMWebAssemblyInfo -lLLVMSystemZDisassembler -lLLVMSystemZCodeGen -lLLVMSystemZAsmParser -lLLVMSystemZDesc -lLLVMSystemZInfo -lLLVMSparcDisassembler -lLLVMSparcCodeGen -lLLVMSparcAsmParser -lLLVMSparcDesc -lLLVMSparcInfo -lLLVMPowerPCDisassembler -lLLVMPowerPCCodeGen -lLLVMPowerPCAsmParser -lLLVMPowerPCDesc -lLLVMPowerPCInfo -lLLVMNVPTXCodeGen -lLLVMNVPTXDesc -lLLVMNVPTXInfo -lLLVMMSP430Disassembler -lLLVMMSP430CodeGen -lLLVMMSP430AsmParser -lLLVMMSP430Desc -lLLVMMSP430Info -lLLVMMipsDisassembler -lLLVMMipsCodeGen -lLLVMMipsAsmParser -lLLVMMipsDesc -lLLVMMipsInfo -lLLVMLanaiDisassembler -lLLVMLanaiCodeGen -lLLVMLanaiAsmParser -lLLVMLanaiDesc -lLLVMLanaiInfo -lLLVMHexagonDisassembler -lLLVMHexagonCodeGen -lLLVMHexagonAsmParser -lLLVMHexagonDesc -lLLVMHexagonInfo -lLLVMBPFDisassembler -lLLVMBPFCodeGen -lLLVMBPFAsmParser -lLLVMBPFDesc -lLLVMBPFInfo -lLLVMARMDisassembler -lLLVMARMCodeGen -lLLVMARMAsmParser -lLLVMARMDesc -lLLVMARMInfo -lLLVMARMUtils -lLLVMAMDGPUDisassembler -lLLVMAMDGPUCodeGen -lLLVMAMDGPUAsmParser -lLLVMAMDGPUDesc -lLLVMAMDGPUInfo -lLLVMAMDGPUUtils -lLLVMAArch64Disassembler -lLLVMAArch64CodeGen -lLLVMAArch64AsmParser -lLLVMAArch64Desc -lLLVMAArch64Info -lLLVMAArch64Utils -lLLVMObjectYAML -lLLVMLibDriver -lLLVMOption -lLLVMWindowsManifest -lLLVMTextAPI -lLLVMFuzzMutate -lLLVMX86Disassembler -lLLVMX86AsmParser -lLLVMX86CodeGen -lLLVMGlobalISel -lLLVMSelectionDAG -lLLVMAsmPrinter -lLLVMX86Desc -lLLVMMCDisassembler -lLLVMX86Info -lLLVMMCJIT -lLLVMLineEditor -lLLVMInterpreter -lLLVMExecutionEngine -lLLVMRuntimeDyld -lLLVMCodeGen -lLLVMTarget -lLLVMCoroutines -lLLVMipo -lLLVMInstrumentation -lLLVMVectorize -lLLVMScalarOpts -lLLVMLinker -lLLVMIRReader -lLLVMAsmParser -lLLVMInstCombine -lLLVMBitWriter -lLLVMAggressiveInstCombine -lLLVMTransformUtils -lLLVMAnalysis -lLLVMProfileData -lLLVMObject -lLLVMMCParser -lLLVMMC -lLLVMDebugInfoCodeView -lLLVMDebugInfoMSF -lLLVMBitReader -lLLVMCore -lLLVMBinaryFormat -lLLVMSupport -lLLVMDemangle -lLLVMRemarks -lLLVMFrontendOpenMP -lLLVMBitstreamReader -lclangASTMatchers -lLLVMRISCVAsmParser -lclangSupport -lLLVMWindowsDriver")

set(LLVM_LIBDIR "${LLVM_ROOT}/lib_${METADATA_BINARY_ARCH}")
set(LLVM_LINKER_FLAGS "-L${LLVM_LIBDIR} -Wl,-search_paths_first -Wl,-headerpad_max_install_names -Wl,-dead_strip")

set(CMAKE_BUILD_TYPE Release)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -target ${METADATA_BINARY_ARCH}-apple-darwin -std=c++17 -fno-rtti ${LLVM_PREPROCESSOR_FLAGS}")

# Disable unused-but-set-variable error because it's triggered by LLVM code
check_c_compiler_flag(-Wno-unused-but-set-variable HAS_UNUSED_BUT_SET_VARIABLE)
if (HAS_UNUSED_BUT_SET_VARIABLE)
    add_compile_options(-Wno-unused-but-set-variable)
endif()

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
