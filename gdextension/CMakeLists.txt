cmake_minimum_required(VERSION 3.17)

# DevECS 原生核心 (GDExtension)
# 独立 ECS 底层: 实体/组件/系统/查询, 与 DEVFramework 原有逻辑完全隔离。
# 多平台构建: godot-cpp 官方模板同款 CMake 方案
# 用法:
#   cmake -S . -B build -DGODOTCPP_API_VERSION=4.7 -DCMAKE_BUILD_TYPE=Release
#   cmake --build build --config Release
# 平台支持: macOS(arm64/x86_64) / Windows(x86_64) / Linux(x86_64)

project(devecs LANGUAGES CXX)

if(NOT DEFINED GODOTCPP_API_VERSION)
    set(GODOTCPP_API_VERSION "4.7")
endif()

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp ${CMAKE_CURRENT_BINARY_DIR}/godot-cpp)

add_library(devecs SHARED
    src/register_types.cpp
    src/ecs_core.cpp
)

target_link_libraries(devecs PRIVATE godot-cpp)

set_target_properties(devecs PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)

# 性能优化: 本机全部 SIMD 指令集(自动向量化)。
# 注意: -march=native 生成的 DLL 依赖本机 CPU, 仅用于本机开发构建。
# (w64devkit 的 GCC 未启用 LTO, 故仅用 -march=native)
if(NOT MSVC)
    target_compile_options(devecs PRIVATE -march=native)
endif()

if(APPLE)
    set_target_properties(devecs PROPERTIES MACOSX_RPATH ON)
endif()

# 编译产物直接输出到插件分发目录 addons/DEVFramework/Entity/ECS/Native/
set_target_properties(devecs PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Entity/ECS/Native
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Entity/ECS/Native
    ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Entity/ECS/Native
)
