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
# 注意: -march=native 生成的二进制依赖本机 CPU, 仅用于"目标架构=本机架构"的构建。
# macOS 交叉构建(如 arm64 主机出 x86_64)时 native 会按本机 CPU 解析成 apple-m1,
# x86 后端不认识该 CPU 名而报 "unknown target CPU", 此时自动降级:
#   单一架构交叉 x86_64 → x86-64-v2 基线(SSE4.2/POPCNT, 2009+ x86 CPU 全支持);
#   universal 双架构 → 不加 -march(双架构共享 flags, 用编译器默认基线)。
# (w64devkit 的 GCC 未启用 LTO, 故仅用 -march=native)
if(NOT MSVC)
    set(_dev_native ON)          # 默认本机构建 → native
    if(APPLE)
        execute_process(COMMAND uname -m OUTPUT_VARIABLE _dev_host OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
        set(_dev_target "${CMAKE_OSX_ARCHITECTURES}")
        if(_dev_target STREQUAL "")
            set(_dev_target "${_dev_host}")
        endif()
        if(NOT _dev_target STREQUAL _dev_host OR _dev_target MATCHES ";")
            set(_dev_native OFF) # 交叉或 universal
        endif()
    endif()
    if(_dev_native)
        target_compile_options(dev PRIVATE -march=native)
    elseif(_dev_target STREQUAL "x86_64")
        target_compile_options(dev PRIVATE -march=x86-64-v2)
    endif()
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