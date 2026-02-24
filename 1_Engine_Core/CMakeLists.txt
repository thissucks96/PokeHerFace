cmake_minimum_required(VERSION 3.15)
project(shark LANGUAGES CXX)

# 1. Compiler settings
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(MSVC)
  add_compile_options(/O2 /fp:fast)
else()
  add_compile_options(-O3 -ffast-math)
endif()

if(WIN32)
  add_compile_definitions(NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

# 1.1 Optional LibTorch bridge (C++ PyTorch)
option(ENABLE_LIBTORCH "Enable LibTorch integration if available" ON)
set(LIBTORCH_ROOT "${CMAKE_SOURCE_DIR}/../libs/libtorch" CACHE PATH "Path to LibTorch root")
if(ENABLE_LIBTORCH)
  if(EXISTS "${LIBTORCH_ROOT}/share/cmake/Torch/TorchConfig.cmake")
    list(APPEND CMAKE_PREFIX_PATH "${LIBTORCH_ROOT}")
  endif()
  find_package(Torch QUIET)
  if(Torch_FOUND)
    message(STATUS "LibTorch found: ${TORCH_VERSION}")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${TORCH_CXX_FLAGS}")
    add_definitions(-DSHARK_USE_LIBTORCH=1)
  else()
    message(STATUS "LibTorch not found. Set LIBTORCH_ROOT to your extracted libtorch folder.")
  endif()
endif()

# 2. Static linking setup
if(APPLE OR UNIX)
  message(STATUS "Enabling static linking for TBB and FLTK")
  set(FLTK_USE_STATIC_LIBS ON)
  add_definitions(-DSTATIC_FLTK)

  if(APPLE)
    # Use Homebrew paths - works for both Intel (/usr/local) and ARM (/opt/homebrew)
    execute_process(COMMAND brew --prefix OUTPUT_VARIABLE BREW_PREFIX OUTPUT_STRIP_TRAILING_WHITESPACE)
    set(FLTK_STATIC_LIB ${BREW_PREFIX}/opt/fltk/lib/libfltk.a)
    set(FLTK_IMAGES_STATIC_LIB ${BREW_PREFIX}/opt/fltk/lib/libfltk_images.a)
    set(TBB_STATIC_LIB ${BREW_PREFIX}/opt/tbb/lib/libtbb.a)
    # Static image libraries - must use .a files, not CMake targets (which link dynamically)
    set(PNG_STATIC_LIB ${BREW_PREFIX}/opt/libpng/lib/libpng.a)
    set(JPEG_STATIC_LIB ${BREW_PREFIX}/opt/jpeg/lib/libjpeg.a)
    set(ZLIB_STATIC_LIB ${BREW_PREFIX}/opt/zlib/lib/libz.a)
  else() # Linux
    set(FLTK_STATIC_LIB /usr/lib/x86_64-linux-gnu/libfltk.a)
    set(FLTK_IMAGES_STATIC_LIB /usr/lib/x86_64-linux-gnu/libfltk_images.a)
    set(TBB_STATIC_LIB /usr/lib/x86_64-linux-gnu/libtbb.a)
  endif()
endif()

# 3. Find dependencies
# On Windows/vcpkg, prefer config packages to avoid legacy FindFLTK lookup issues.
set(SHARK_USE_FLTK_CONFIG OFF)
if(WIN32)
  find_package(FLTK CONFIG QUIET)
  if(FLTK_FOUND)
    set(SHARK_USE_FLTK_CONFIG ON)
  endif()
endif()
if(NOT SHARK_USE_FLTK_CONFIG)
  find_package(FLTK REQUIRED)
endif()
find_package(TBB REQUIRED)

# Image libraries for FLTK PNG/JPEG support
find_package(PNG REQUIRED)
find_package(JPEG REQUIRED)
find_package(ZLIB REQUIRED)

# 4. PokerHandEvaluator subproject
set(BUILD_CARD5    OFF CACHE BOOL "" FORCE)
set(BUILD_CARD6    OFF CACHE BOOL "" FORCE)
set(BUILD_CARD7    OFF CACHE BOOL "" FORCE)
set(BUILD_PLO4     OFF CACHE BOOL "" FORCE)
set(BUILD_PLO5     OFF CACHE BOOL "" FORCE)
set(BUILD_PLO6     OFF CACHE BOOL "" FORCE)
set(BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
add_subdirectory(include/PokerHandEvaluator/cpp pheval_build)

# 5. Source files
file(GLOB_RECURSE POKER_GUI_SRCS
  gui/gui.cpp
  gui/components/*.cpp
  src/hands/*.cpp
  src/solver/*.cpp
  src/trainer/*.cpp
  src/tree/*.cpp
)

# 6. Executable (with platform-specific icon resources)
if(WIN32)
  set(PLATFORM_RESOURCES gui/shark.rc)
elseif(APPLE)
  set(MACOSX_BUNDLE_ICON_FILE generated_logo.icns)
  set(APP_ICON ${CMAKE_SOURCE_DIR}/icons/generated_logo.icns)
  set_source_files_properties(${APP_ICON} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
  set(PLATFORM_RESOURCES ${APP_ICON})
endif()

if(APPLE)
  add_executable(shark MACOSX_BUNDLE ${POKER_GUI_SRCS} ${PLATFORM_RESOURCES})
  set_target_properties(shark PROPERTIES
    MACOSX_BUNDLE_BUNDLE_NAME "Shark 2.0"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.shark.pokersolver"
    MACOSX_BUNDLE_ICON_FILE "generated_logo.icns"
  )
elseif(WIN32)
  add_executable(shark WIN32 ${POKER_GUI_SRCS} ${PLATFORM_RESOURCES})
else()
  add_executable(shark ${POKER_GUI_SRCS})
endif()

# 7. Include paths
set(SHARK_EXTRA_INCLUDES "")
if(DEFINED FLTK_INCLUDE_DIR AND NOT SHARK_USE_FLTK_CONFIG)
  list(APPEND SHARK_EXTRA_INCLUDES ${FLTK_INCLUDE_DIR})
endif()

target_include_directories(shark PRIVATE
  ${CMAKE_SOURCE_DIR}/src
  ${CMAKE_SOURCE_DIR}/include
  ${CMAKE_SOURCE_DIR}/gui
  ${SHARK_EXTRA_INCLUDES}
)

# 8. Link libraries (fltk_images must come before fltk, image libs after)
if(APPLE)
  target_link_libraries(shark PRIVATE
    ${FLTK_IMAGES_STATIC_LIB}
    ${FLTK_STATIC_LIB}
    ${TBB_STATIC_LIB}
    pheval
    ${PNG_STATIC_LIB}
    ${JPEG_STATIC_LIB}
    ${ZLIB_STATIC_LIB}
    "-framework Cocoa"
    "-framework ApplicationServices"
    "-framework CoreFoundation"
    "-framework Carbon"
    "-framework IOKit"
    "-framework ScreenCaptureKit"
  )
elseif(UNIX)
  target_link_libraries(shark PRIVATE
    ${FLTK_IMAGES_STATIC_LIB}
    ${FLTK_STATIC_LIB}
    ${TBB_STATIC_LIB}
    pheval
    PNG::PNG
    JPEG::JPEG
    ZLIB::ZLIB
    m pthread dl X11 Xext Xft fontconfig Xrender Xinerama Xcursor Xfixes
  )
else()
  # Windows - FLTK uses system PNG/JPEG directly (no fltk_png/fltk_jpeg)
  if(SHARK_USE_FLTK_CONFIG)
    set(SHARK_FLTK_LIBS fltk_images fltk)
  else()
    set(SHARK_FLTK_LIBS fltk_images ${FLTK_LIBRARIES})
  endif()
  target_link_libraries(shark PRIVATE
    ${SHARK_FLTK_LIBS}
    TBB::tbb
    pheval
    PNG::PNG
    JPEG::JPEG
    ZLIB::ZLIB
    dwmapi
  )
endif()

if(Torch_FOUND)
  target_link_libraries(shark PRIVATE "${TORCH_LIBRARIES}")
endif()

if(WIN32)
  function(shark_copy_runtime_dlls target_name)
    # Copy transitive runtime DLLs (vcpkg/FLTK/TBB/etc.) next to the executable.
    add_custom_command(TARGET ${target_name} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
      $<TARGET_RUNTIME_DLLS:${target_name}>
      $<TARGET_FILE_DIR:${target_name}>
      COMMAND_EXPAND_LISTS
    )

    # Torch sometimes needs explicit copying of its CUDA DLL set.
    if(Torch_FOUND AND DEFINED TORCH_INSTALL_PREFIX)
      file(GLOB TORCH_DLLS "${TORCH_INSTALL_PREFIX}/lib/*.dll")
      if(TORCH_DLLS)
        add_custom_command(TARGET ${target_name} POST_BUILD
          COMMAND ${CMAKE_COMMAND} -E copy_if_different
          ${TORCH_DLLS}
          $<TARGET_FILE_DIR:${target_name}>
          COMMAND_EXPAND_LISTS
        )
      endif()
    endif()
  endfunction()

  shark_copy_runtime_dlls(shark)
endif()

# 9. CLI test executable (no GUI)
file(GLOB_RECURSE SOLVER_SRCS
  src/hands/*.cpp
  src/solver/*.cpp
  src/trainer/*.cpp
  src/tree/*.cpp
)
add_executable(shark_cli src/main.cpp ${SOLVER_SRCS})
target_include_directories(shark_cli PRIVATE
  ${CMAKE_SOURCE_DIR}/src
  ${CMAKE_SOURCE_DIR}/include
)
if(APPLE)
  target_link_libraries(shark_cli PRIVATE ${TBB_STATIC_LIB} pheval)
elseif(UNIX)
  target_link_libraries(shark_cli PRIVATE ${TBB_STATIC_LIB} pheval m pthread dl)
else()
  target_link_libraries(shark_cli PRIVATE TBB::tbb pheval)
endif()

if(Torch_FOUND)
  target_link_libraries(shark_cli PRIVATE "${TORCH_LIBRARIES}")
endif()

if(WIN32)
  shark_copy_runtime_dlls(shark_cli)
endif()
