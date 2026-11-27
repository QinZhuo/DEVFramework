# gdextension 构建区

本目录只放构建脚手架（CMake 工程、godot-cpp submodule、生成的源文件清单），**不放源码**。
源码与产物都在插件自己的 `Native/` 下，这样把 `addons/<插件>/` 整个拷到新项目仍然能构建。

| 东西 | 真实位置 |
|---|---|
| C++ 源码 | `addons/DEVFramework/Native/src/`（`ecs_core.cpp/.h`、`register_types.cpp/.h`） |
| 源文件清单 | `gdextension/generated/devframework_sources.cmake`（**每次构建刷新，勿手改**） |
| CMake 工程 | `gdextension/CMakeLists.txt`（一个工程多个 target，共用一份 godot-cpp 构建） |
| godot-cpp | `gdextension/godot-cpp/`（git submodule，未 init 时为空） |
| 产物 | `addons/DEVFramework/Native/libdevframework.<平台>.<debug 或 release>.<架构>.<ext>` |
| 加载声明 | `addons/DEVFramework/Native/devframework.gdextension` |
| 构建缓存 / 日志 | `res://.godot/gdextension_build/`（`build.log`、`last_build.txt`、`state.txt`） |

## 构建

三种入口走同一份实现（`GDExtensionRebuild`）：

| 入口 | 用法 | 适合 |
|---|---|---|
| MCP 工具 | `build_native`（`action=status` 只比时间戳 / `action=build` 必带 `plugin=<target>`，`restart=true` 完成后自动重载） | AI / 自动化，改完 C++ 的首选 |
| 编辑器菜单 | 项目 → 工具 → EditorScript → `GDExtensionRebuild` | 人手点一下（构建全部 target） |
| 原始 CMake | 下面两行 + 按 `[libraries]` 手动改名 | 排障 |

```bash
git submodule update --init --recursive        # 首次克隆后初始化 godot-cpp

cmake -S gdextension -B gdextension/build -DCMAKE_BUILD_TYPE=Release -DGODOTCPP_API_VERSION=4.7
cmake --build gdextension/build --config Release --target devframework
```

`-DGODOTCPP_API_VERSION` 可省略（CMakeLists 默认 4.7）。配置项在 `项目设置 → dev_framework/gdextension_build/*`。

## 产物命名

CMake 的 `*_OUTPUT_DIRECTORY` 已把库直出到 `addons/DEVFramework/Native/`，但**链接器直出的是默认名**，必须改成 `.gdextension` 声明的规范名：

| 平台 | 默认名 | 规范名 |
|---|---|---|
| Windows | `devframework.dll` | `libdevframework.windows.release.x86_64.dll` |
| macOS | `libdevframework.dylib` | `libdevframework.macos.release.universal.dylib` |
| Linux | `libdevframework.so` | `libdevframework.linux.release.x86_64.so` |

规范名规则 `lib<target>.<平台>.<debug|release>.<架构>.<ext>`；`lib` 前缀必须有，唯一硬约束是 `[libraries]` 与磁盘文件名一字不差。编辑器一键构建会自动改名。
**不要在 CMakeLists 里加 `OUTPUT_NAME` 去直接产出规范名**：部署工具靠"默认名 + 本次链接时间"识别新产物，改了会让探测失效。

## 坑

1. 引擎只在启动时加载 `.gdextension`：部署后必须重启编辑器（或项目 → 重新加载当前项目）才生效；Windows 上编辑器锁住已加载的 dll，覆盖失败时工具会打印手动复制指引。
2. 未初始化 `godot-cpp` submodule 无法构建。
3. `build_native action=build` 必须指定 `plugin`（target 名，如 `devframework`）；只构建一个 target 时不要传 `all`，否则没改的插件也会被重链、产物时间戳跟着变。
4. 过期检测：`action=status` 比较"该 target 自己的源码目录"与"该 target 自己的产物"时间戳，`test_framework_compile` 的 `test_native_library_is_fresh` 会在源码比库新时判红。
