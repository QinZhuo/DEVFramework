# NativeSrc — 框架级共享原生核心(源码)

整个 DEVFramework 唯一的 C++ 共享扩展：`ECSCore` 等原生类都注册在这一个库里，GDScript 侧统一用
`FrameworkNative.get_native(&"类名", [方法...])` 访问。

**为什么源码放在插件目录里**：把 `addons/DEVFramework/` 整个拷到新项目就能构建，不需要在项目根再建
`gdextension/`。目录带 `.gdignore`，编辑器不会去扫 `godot-cpp/` 的上万个文件。

```
addons/DEVFramework/
├── NativeSrc/            ← 本目录(C++ 源码 + 构建配置, 整个被 .gdignore 忽略)
│   ├── .gdignore
│   ├── CMakeLists.txt
│   ├── src/              ← 自己的源码(新增类放这里)
│   └── godot-cpp/        ← git submodule
└── Native/               ← 构建产物 + dev.gdextension(引擎从这里加载)
```

## 构建

产物输出到 `res://addons/DEVFramework/Native/`，文件名必须与 `Native/dev.gdextension` 的条目严格对应：

| 平台 | Debug | Release |
|---|---|---|
| Windows x86_64 | `dev.windows.debug.x86_64.dll` | `dev.windows.release.x86_64.dll` |
| Linux x86_64 | `libdev.linux.debug.x86_64.so` | `libdev.linux.release.x86_64.so` |
| macOS arm64 | `libdev.macos.debug.arm64.dylib` | `libdev.macos.release.arm64.dylib` |
| macOS x86_64 | `libdev.macos.debug.x86_64.dylib` | `libdev.macos.release.x86_64.dylib` |

```bash
git submodule update --init --recursive        # 首次克隆后初始化 godot-cpp

cmake -S addons/DEVFramework/NativeSrc -B addons/DEVFramework/NativeSrc/build \
      -DGODOTCPP_API_VERSION=4.7 -DCMAKE_BUILD_TYPE=Release
cmake --build addons/DEVFramework/NativeSrc/build --config Release
```

三种入口，构建流程是同一份实现（`GDExtensionRebuild`）：

| 入口 | 用法 | 适合 |
|---|---|---|
| MCP 工具 | `build_native`（`action=status` 查过期 / `action=build` 构建，`restart=true` 完成后自动重载） | AI / 自动化；**改完 C++ 的第一选择** |
| 编辑器菜单 | **项目 → 工具 → EditorScript → GDExtensionRebuild** | 人手点一下 |
| 原始 CMake | 上面的两行命令 + 手动按 `[libraries]` 改名 | 排查构建问题 |

- 配置在 `项目设置 → dev_framework/gdextension_build/*`（并行度、是否自动同步 godot-cpp、完成后是否自动重载等）。
- 构建缓存：`res://.godot/gdextension_build/`；日志 `build.log`，摘要 `last_build.txt`，实时阶段 `state.txt`。
- **过期检测**：`build_native action=status` 比较源码与产物时间戳；`test_framework_compile` 的
  `test_native_library_is_fresh` 会在"源码比库新"时直接判红 —— 这就是"改了 C++ 忘了重编"的自动兜底。

新增原生类：`src/` 建 `.cpp/.h` → 在 `src/register_types.cpp` 注册 → 加入 `CMakeLists.txt` 的 `add_library(dev SHARED ...)` → 重编译部署。

## 坑

1. 引擎只在启动时加载 `.gdextension`：部署后必须 **项目 → 重新加载当前项目** 才生效。Windows 上编辑器会锁住已加载的 dll，覆盖失败时工具会打印手动复制指引。
2. CMake 原始产物无平台后缀（`dev.dll` / `libdev.so`），必须按上表重命名，否则不会被加载。
3. 未初始化 `godot-cpp` submodule 无法构建。
