# gdextension — 框架级共享原生核心

整个 DEVFramework 唯一的 C++ 共享扩展：`ECSCore` 等原生类都注册在这一个库里，GDScript 侧统一用 `FrameworkNative.get_native(&"类名", [方法...])` 访问。

## 构建

产物输出到 `res://addons/DEVFramework/Native/`，文件名必须与 `Native/dev.gdextension` 的 8 个平台条目严格对应：

| 平台 | Debug | Release |
|---|---|---|
| Windows x86_64 | `dev.windows.debug.x86_64.dll` | `dev.windows.release.x86_64.dll` |
| Linux x86_64 | `libdev.linux.debug.x86_64.so` | `libdev.linux.release.x86_64.so` |
| macOS arm64 | `libdev.macos.debug.arm64.dylib` | `libdev.macos.release.arm64.dylib` |
| macOS x86_64 | `libdev.macos.debug.x86_64.dylib` | `libdev.macos.release.x86_64.dylib` |

```bash
git submodule update --init --recursive        # 首次克隆后初始化 godot-cpp

cmake -S gdextension -B gdextension/build -DGODOTCPP_API_VERSION=4.7 -DCMAKE_BUILD_TYPE=Release
cmake --build gdextension/build --config Release
```

更省事：菜单 **项目 → 工具 → EditorScript → GDExtensionRebuild** 一键配置 + 异步编译 + 按 `[libraries]` 改名部署，构建缓存在 `res://.godot/gdextension_build/`。

新增原生类：`src/` 建 `.cpp/.h` → 在 `src/register_types.cpp` 注册 → 加入 `CMakeLists.txt` 的 `add_library(dev SHARED ...)` → 重编译部署。

## 坑

1. 引擎只在启动时加载 `.gdextension`：部署后必须 **项目 → 重新加载当前项目** 才生效。Windows 上编辑器会锁住已加载的 dll，覆盖失败时工具会打印手动复制指引。
2. CMake 原始产物无平台后缀（`dev.dll` / `libdev.so`），必须按上表重命名，否则不会被加载。
3. 未初始化 `godot-cpp` submodule 无法构建。
