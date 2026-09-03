cmake_minimum_required(VERSION 3.17)

# Dev 原生核心 (GDExtension) — DEVFramework 框架级共享原生库
# 整个框架的 C++ 能力(ECS / PCG / Audio 等)都注册在这一个扩展里,
# 编译产物统一输出到 addons/DEVFramework/Native/。
# 多平台构建: godot-cpp 官方模板同款 CMake 方案
# 用法:
#   cmake -S . -B build -DGODOTCPP_API_VERSION=4.7 -DCMAKE_BUILD_TYPE=Release
#   cmake --build build --config Release
# 平台支持: macOS(arm64/x86_64) / Windows(x86_64) / Linux(x86_64)

project(dev LANGUAGES CXX)

if(NOT DEFINED GODOTCPP_API_VERSION)
    set(GODOTCPP_API_VERSION "4.7")
endif()

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp ${CMAKE_CURRENT_BINARY_DIR}/godot-cpp)

add_library(dev SHARED
    src/register_types.cpp
    src/audio_synth.cpp
    src/ecs_core.cpp
    src/pcg_erode.cpp
    src/pcg_wfc.cpp
    src/pcg_wfc3d.cpp
    src/pcg_wfc_animator.cpp
    src/pcg_lsystem.cpp
    src/pcg_cave3d.cpp
)

target_link_libraries(dev PRIVATE godot-cpp)

set_target_properties(dev PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)

# 性能优化: 本机全部 SIMD 指令集(自动向量化)。
# 注意: -march=native 生成的 DLL 依赖本机 CPU, 仅用于本机开发构建。
# (w64devkit 的 GCC 未启用 LTO, 故仅用 -march=native)
if(NOT MSVC)
    target_compile_options(dev PRIVATE -march=native)
    # 禁用 FMA 融合: 使逐采样 float 运算与 Godot 引擎语义一致(引擎构建未开 FMA),
    # 保证 C++ 音频合成输出与旧 GDScript 渲染 bit 级一致(迁移无感)。
    target_compile_options(dev PRIVATE -ffp-contract=off)
endif()

if(APPLE)
    set_target_properties(dev PROPERTIES MACOSX_RPATH ON)
endif()

# 产物命名无需在此钉 OUTPUT_NAME —— GDExtensionRebuild 会把直出产物统一改名为规范名
# (libdev.macos.debug.arm64.dylib 等, 与 addons/DEVFramework/Native/dev.gdextension [libraries] 对应)。
# 可选: 若希望 CMake 直出名即规范名(零改名), 可加各平台条件块 OUTPUT_NAME, 工具自动兼容。

# 编译产物直接输出到框架级共享原生库目录 addons/DEVFramework/Native/
set_target_properties(dev PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Native
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Native
    ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Native
)