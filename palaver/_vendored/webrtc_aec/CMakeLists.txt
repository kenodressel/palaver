cmake_minimum_required(VERSION 3.16)
project(raven_aec VERSION 1.0.0 LANGUAGES C CXX)

# -----------------------------------------------------------------------------
# Notes for palaver vendor fork
# -----------------------------------------------------------------------------
# The upstream project-raven CMakeLists.txt compiles src/aec_api.cpp from
# source, but that requires WebRTC internal headers (e.g.
#   webrtc/modules/audio_processing/include/audio_processing.h
#   webrtc/modules/interface/module_common_types.h
# ) that the upstream repo does NOT ship — `third_party/webrtc/` is an empty
# directory on disk and `include/webrtc/audio_processing.h` is a flat stub
# rather than the real layered layout.
#
# Re-building WebRTC from source is out of scope (hours of work, needs
# depot_tools etc.). Instead, we consume upstream's pre-built
# `lib/Darwin/libraven_aec.a` (arm64, contains a fully-compiled
# `aec_api.cpp.o`) and link it together with the WebRTC static libs and
# macOS frameworks into a loadable dylib for ctypes.
#
# src/aec_api.cpp and include/ are kept for reference / license compliance
# but are NOT compiled here.
# -----------------------------------------------------------------------------

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT APPLE)
    message(FATAL_ERROR
        "This vendored raven_aec build currently supports macOS only. "
        "Upstream has Windows libs in lib/windows; adapt here if needed.")
endif()

set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS version")

# Pre-built object archives from upstream project-raven.
set(RAVEN_AEC_ARCHIVE ${CMAKE_CURRENT_SOURCE_DIR}/lib/Darwin/libraven_aec.a)
set(WEBRTC_LIB_DIR    ${CMAKE_CURRENT_SOURCE_DIR}/lib/macos)

if(NOT EXISTS ${RAVEN_AEC_ARCHIVE})
    message(FATAL_ERROR "Missing pre-built ${RAVEN_AEC_ARCHIVE}")
endif()

# Produce a loadable shared library (ctypes can't dlopen .a archives).
# We can't start from an empty SHARED target because there's no C/C++ source
# to compile here — instead we define a tiny placeholder TU and let the
# linker pull every symbol from libraven_aec.a via -force_load.
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/_raven_aec_stub.cpp
    "// Placeholder TU; real symbols come from libraven_aec.a via -force_load.\n")

add_library(raven_aec SHARED ${CMAKE_CURRENT_BINARY_DIR}/_raven_aec_stub.cpp)

set_target_properties(raven_aec PROPERTIES
    OUTPUT_NAME raven_aec
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
)

find_library(ACCELERATE_FRAMEWORK Accelerate)
find_library(AUDIOTOOLBOX_FRAMEWORK AudioToolbox)
find_library(COREAUDIO_FRAMEWORK CoreAudio)

target_link_libraries(raven_aec PRIVATE
    -Wl,-force_load,${RAVEN_AEC_ARCHIVE}
    ${WEBRTC_LIB_DIR}/libwebrtc_audio_processing.a
    ${WEBRTC_LIB_DIR}/libcommon_audio.a
    ${WEBRTC_LIB_DIR}/libsystem_wrappers.a
    ${WEBRTC_LIB_DIR}/libwebrtc.a
    ${ACCELERATE_FRAMEWORK}
    ${AUDIOTOOLBOX_FRAMEWORK}
    ${COREAUDIO_FRAMEWORK}
)

message(STATUS "raven_aec: linking pre-built ${RAVEN_AEC_ARCHIVE}")
message(STATUS "raven_aec: WebRTC libs from ${WEBRTC_LIB_DIR}")
