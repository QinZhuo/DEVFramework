# gdextension — DEVFramework 框架级共享原生核心 (C++ / GDExtension)

**整个 DEVFramework 的唯一 C++ 共享扩展**：ECS 的 `ECSCore`、未来 PCG 侵蚀加速等其他模块原生类
都注册在这一个库里（`res://addons/DEVFramework/Native/devecs.gdextension`），共用一份二进制。
GDScript 侧统一走 `FrameworkNative.get_native(&"类名", [...])` 访问（见 `Native/FrameworkNative.gd`）。

## 目录结构

```
gdextension/
├── CMakeLists.txt      # CMake 构建脚本 (godot-cpp 官方模板同款方案)
├── godot-cpp/          # git submodule (固定 commit，克隆后需 init)
└── src/
    ├── register_types.cpp/.h   # GDExtension 入口注册（新增原生类在此注册）
    └── ecs_core.cpp/.h         # ECS 核心逻辑
```

## 产物分发目录

构建产物统一输出到 `res://addons/DEVFramework/Native/`，
文件名需与 `devecs.gdextension` 中的 8 个平台条目严格对应：

| 平台 | Debug | Release |
|------|-------|---------|
| Windows x86_64 | `devecs.windows.debug.x86_64.dll` | `devecs.windows.release.x86_64.dll` |
| Linux x86_64 | `libdevecs.linux.debug.x86_64.so` | `libdevecs.linux.release.x86_64.so` |
| macOS arm64 | `libdevecs.macos.debug.arm64.dylib` | `libdevecs.macos.release.arm64.dylib` |
| macOS x86_64 | `libdevecs.macos.debug.x86_64.dylib` | `libdevecs.macos.release.x86_64.dylib` |

> CMake 原生输出名为无后缀的 `devecs.dll` / `libdevecs.so` / `libdevecs.dylib`，
> 本地/CI 需按上表重命名后再发布。

## 新增原生能力（模块共享同一扩展）

1. 在 `src/` 新建你的 `.cpp/.h`，在 `src/register_types.cpp` 里 `ClassDB::_register_class` 注册类。
2. `CMakeLists.txt` 的 `add_library(devecs SHARED ...)` 里加入新 `.cpp`。
3. 重编译 → 产物复制到 `addons/DEVFramework/Native/`（按平台后缀命名）。
4. GDScript 侧用 `FrameworkNative.get_native(&"你的类名", [必需方法...])` 获取共享实例，
   **不要**各自再写一套 ClassDB 检测逻辑。

## 本地构建

```bash
# 首次克隆后初始化 godot-cpp submodule
git submodule update --init --recursive

# 编译 (以 Release 为例)
cmake -S gdextension -B gdextension/build -DGODOTCPP_API_VERSION=4.7 -DCMAKE_BUILD_TYPE=Release
cmake --build gdextension/build --config Release

# 产物位于 addons/DEVFramework/Native/ 下 (无后缀名)
# 按上表手动重命名为带平台后缀的文件名后即可使用
```

构建缓存目录 `gdextension/build*/` 已在 `.gitignore` 中忽略，不入库。

### 本地构建示例 (Windows + MinGW)

```bash
# 准备工具链 (以 w64devkit 便携版为例: https://github.com/skeeto/w64devkit)
export PATH="/path/to/w64devkit/bin:$PATH"

# 配置 + 编译 (Ninja 生成器, 输出到 addons/DEVFramework/Native/)
cmake -S gdextension -B gdextension/build-win -G Ninja \
      -DGODOTCPP_API_VERSION=4.7 -DCMAKE_BUILD_TYPE=Release
cmake --build gdextension/build-win

# 产物为无后缀 libdevecs.dll, 需复制为平台带后缀文件名供 .gdextension 加载
cd addons/DEVFramework/Native
cp libdevecs.dll devecs.windows.debug.x86_64.dll
cp libdevecs.dll devecs.windows.release.x86_64.dll
```

> 构建出的 MinGW DLL 仅依赖 `KERNEL32.dll` / `msvcrt.dll`，无额外运行时依赖，可直接分发。
> 已实测：本地构建 Windows 版后运行 `Scenes/ECS/ComponentDemo.tscn` 正常，原生 ECS 核心
> （`ECSCore`）加载成功，20000 海量实体 + 10 关键实体全部由 C++ 核心驱动。

## CI 自动构建 (GitHub Actions)

工作流文件：`.github/workflows/build.yml`

**触发条件**：仅当以下路径发生变化时触发（源码变更）：
- `gdextension/src/**`
- `gdextension/CMakeLists.txt`
- `.gitmodules`
- `.github/workflows/build.yml`

**执行流程**：
1. **build 作业**（4 平台 × debug/release = 8 个任务，原生 runner 矩阵）：
   - Windows x86_64 (`windows-latest`)
   - Linux x86_64 (`ubuntu-latest`)
   - macOS arm64 (`macos-14`) / macOS x86_64 (`macos-13`)
   - 每个任务：checkout（含 submodule）→ cmake 配置 → 编译 → 按上表重命名 → 上传 artifact
2. **commit 作业**（汇总回写）：
   - 下载全部 8 个产物 → 复制到 `addons/DEVFramework/Native/` → 由 `github-actions[bot]` 自动 commit + push

**防死循环设计**：
- 自动回写只修改 `addons/DEVFramework/Native/`，不在触发路径白名单内，不会重新触发构建；
- `GITHUB_TOKEN` 的 push 默认不触发新 workflow 运行，双重保障。

**手动触发**：可在仓库 Actions 页对 `Build DevECS Native` 点击 `Run workflow`。

> 注意：CI 依赖 `gdextension/godot-cpp` submodule，若其指向的 commit 无法编译，需先更新
> submodule 再提交。
