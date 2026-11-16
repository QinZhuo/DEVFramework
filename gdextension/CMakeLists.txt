cmake_minimum_required(VERSION 3.17)

# Dev 原生核心 (GDExtension) — DEVFramework 框架级共享原生库
# 整个框架的 C++ 能力(ECS 等)都注册在这一个扩展里,
# 编译产物统一输出到 addons/DEVFramework/Native/。
# 多平台构建: godot-cpp 官方模板同款 CMake 方案
# 用法:
#   cmake -S . -B build -DGODOTCPP_API_VERSION=4.7 -DCMAKE_BUILD_TYPE=Release
#   cmake --build build --config Release
# 平台支持: macOS(arm64/x86_64) / Windows(x86_64) / Linux(x86_64)

# 目标名 = 插件名(小写, 无 _native 后缀): 产物/入口符号/声明文件都由它派生
project(devframework LANGUAGES CXX)

if(NOT DEFINED GODOTCPP_API_VERSION)
    set(GODOTCPP_API_VERSION "4.7")
endif()

# 符号可见性: GDExtension 只需导出入口函数(GDE_EXPORT 已标 default 可见性), 其余全部隐藏。
# 必须放在 add_subdirectory(godot-cpp) 之前 —— godot-cpp 是静态库, 可见性在编译期烙进 .o,
# 目录级变量才会被子目录继承。不隐藏时, godot-cpp 的内联 weak 符号(如 DefaultAllocator::alloc)
# 会被**同进程加载的多个扩展开各自导出**, 动态链接器做符号抢占(interposing): 某个扩展加载失败后,
# 其未初始化副本会抢占另一个扩展的同名符号, 导致后者调到空函数指针而崩在 _bind_methods 里。
# (参考 GodotVoxelSupport 的实测注释: 与 VoxelSupport 扩展并存时踩过, macOS 上表现为 EXC_BAD_ACCESS)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp ${CMAKE_CURRENT_BINARY_DIR}/godot-cpp)

# 源码位置: 插件自己的 C++ 放在 addons/DEVFramework/Native/src(随插件分发),
# 构建区/第三方(godot-cpp)留在项目根 gdextension/。本文件只做"编排"。
set(DEV_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Native/src)

add_library(devframework SHARED
    ${DEV_SRC_DIR}/register_types.cpp
    ${DEV_SRC_DIR}/ecs_core.cpp
)

target_link_libraries(devframework PRIVATE godot-cpp)

set_target_properties(devframework PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)

# Windows 去掉 lib 前缀: MinGW 默认直出 libdevframework.dll, 而规范名与 .gdextension
# 都是 devframework.windows.<类型>.<架构>.dll —— 直出名与规范名必须一致, 否则部署要靠改名兜底。
# macOS/Linux 保留 lib 前缀(规范名里就有 lib)。
if(WIN32)
    set_target_properties(devframework PROPERTIES PREFIX "")
endif()

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
        target_compile_options(devframework PRIVATE -march=native)
    elseif(_dev_target STREQUAL "x86_64")
        target_compile_options(devframework PRIVATE -march=x86-64-v2)
    endif()
    # 禁用 FMA 融合: 使浮点运算与 Godot 引擎语义一致(引擎构建未开 FMA),
    # 保证 C++ 端结果与 GDScript 侧 bit 级一致。
    target_compile_options(devframework PRIVATE -ffp-contract=off)
endif()

if(APPLE)
    set_target_properties(devframework PROPERTIES MACOSX_RPATH ON)
endif()

# 产物命名无需在此钉 OUTPUT_NAME —— GDExtensionRebuild 会把直出产物统一改名为规范名
# (devframework.windows.release.x86_64.dll 等, 与 addons/DEVFramework/Native/devframework.gdextension 对应)。
# 可选: 若希望 CMake 直出名即规范名(零改名), 可加各平台条件块 OUTPUT_NAME, 工具自动兼容。

# 编译产物直接输出到插件自己的产物目录(声明就在旁边, 引擎直接加载)
set_target_properties(devframework PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Native
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Native
    ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Native
)