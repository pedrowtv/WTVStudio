# Replay Source (Exeldro, GPL-2.0) compilado como módulo da libobs para o motor WTV.
# Projecto autónomo: não é incluído pelo engine-obs/CMakeLists.txt.
#   cmake -S engine-obs/third_party/obs-replay-source -B ~/.cache/wtv-obs/replay-build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
#   cmake --build ~/.cache/wtv-obs/replay-build
# Produto: <build>/replay-source.plugin/Contents/{MacOS/replay-source, Resources/locale/*.ini, Info.plist}
cmake_minimum_required(VERSION 3.28)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "tipo de build" FORCE) # sem isto o plugin compilava sem optimização
endif()
project(replay-source VERSION 1.8.1 LANGUAGES C)

# Mesmos caminhos do engine-obs/CMakeLists.txt (docs/INSTALACAO.md, "Motor sobre a libobs")
set(OBS_BUILD_DIR "$ENV{HOME}/.cache/wtv-obs/build" CACHE PATH "build do obs-studio")
set(OBS_SRC_DIR "$ENV{HOME}/.cache/wtv-obs/obs-studio" CACHE PATH "fontes do obs-studio")
set(OBS_DEPS_DIR "${OBS_SRC_DIR}/.deps/obs-deps-2025-08-23-universal" CACHE PATH "obs-deps pré-compiladas")
set(OBS_FW "${OBS_BUILD_DIR}/libobs/RelWithDebInfo/libobs.framework")

if(NOT EXISTS "${OBS_FW}/libobs")
  message(FATAL_ERROR "libobs.framework não encontrada em ${OBS_FW}; compila o OBS primeiro (docs/INSTALACAO.md)")
endif()

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_VISIBILITY_PRESET default)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 12.0 CACHE STRING "" FORCE)
set(CMAKE_COMPILE_WARNING_AS_ERROR OFF)

add_library(replay-source MODULE
  replay.c
  replay-source.c
  replay-filter.c
  replay-filter-audio.c
  replay-filter-async.c
  stub/stub.c
  replay.h
  version.h)

target_include_directories(replay-source PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/stub"
  "${OBS_FW}/Headers"
  "${OBS_SRC_DIR}/libobs"
  "${OBS_BUILD_DIR}/config"
  "${OBS_DEPS_DIR}/include")
target_link_libraries(replay-source PRIVATE "${OBS_FW}/libobs")
# O clang do Xcode 26 é estrito: avisos ficam como avisos, nunca erros.
target_compile_options(replay-source PRIVATE -Wall -Wno-error -Wno-unused-parameter -Wno-deprecated-declarations)

# Bundle no formato que a libobs carrega: <dir>/%module%.plugin/Contents/MacOS/%module%
set(PLUGIN_BUNDLE "${CMAKE_BINARY_DIR}/replay-source.plugin")
set_target_properties(replay-source PROPERTIES
  PREFIX ""
  SUFFIX ""
  OUTPUT_NAME "replay-source"
  LIBRARY_OUTPUT_DIRECTORY "${PLUGIN_BUNDLE}/Contents/MacOS"
  # Mesma rpath dos plugins do OBS: dentro de WTV Engine.app resolve Contents/Frameworks; em dev o
  # run-dev.sh exporta DYLD_FRAMEWORK_PATH e a libobs já está carregada pelo motor.
  BUILD_WITH_INSTALL_RPATH ON
  INSTALL_RPATH "@executable_path/../Frameworks")

configure_file("${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in" "${PLUGIN_BUNDLE}/Contents/Info.plist" @ONLY)
add_custom_command(TARGET replay-source POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "${PLUGIN_BUNDLE}/Contents/Resources"
  COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/data/locale" "${PLUGIN_BUNDLE}/Contents/Resources/locale"
  COMMENT "A copiar locale para ${PLUGIN_BUNDLE}/Contents/Resources")
