# 分层与命名约定

新增代码前先过「归属」；命名不对就别提交。

## 一、归属：框架还是项目

| # | 自问 | 是 → |
|---|---|---|
| 1 | 换个游戏这段代码一字不改还能用？ | 框架 |
| 2 | 去掉具体语义还剩一个通用骨架？ | 骨架进框架，具体留项目 |
| 3 | 引用具体项目资源或类？ | 项目 |
| 4 | 含游戏语义（伤害公式、存档字段、联机策略）？ | 项目 |
| 5 | 纯数学 / 纯结构（状态机、修饰符、序列化）？ | 框架 |

## 二、形态：它长什么样

命中即停：

1. 编辑器可配、要存档 → `Def`（`Assets/Def/*.tres`，必带 `@tool`）
2. 只有运行时存在、有状态 → `Entity` / `Entity2D` / `Entity3D`
3. 玩家看得见或要交互 → `View`（一律 `.tscn` 搭，不代码生成）
4. 横切、无实例状态 → `Tool`（`class_name XxxTool extends RefCounted`，全 static）
5. 每帧被批量调度 → `XxxSystem`
6. 都不是 → 你在造第五种角色，停下重想

**禁用同义词**：`Service` / `Processor` / `Handler` / `Driver` / `Runner` / `Brain` / `Planner`。

## 三、目录

| 位置 | 放什么 |
|---|---|
| `Core/{Def,Entity,Tool,Async,Pool,Editor}` | 跨能力复用、无业务语义 |
| `<能力>/{Def,Entity,View,Tool,Editor}` | 一个能力一个目录，自包含 |
| `Native/` | 原生库 + `dev.gdextension`，**禁止移动**（路径写死在配置里） |

- **目录名 = 能力名**。找不到对应能力，说明这个能力还没起名 —— 先起名再建目录。
- 内部层名固定五个；**少于 3 个文件就扁平**，不为 1 个文件建子目录。
- 不再有 `View/` `Tool/` 这种跨能力层目录（旧结构，已拆散）。
- 例外：`MCP/` 扁平（内部 preload 硬编码网 + autoload）。

## 四、命名

### 脚本文件与类名

| 规则 | 说明 |
|---|---|
| **文件名 = 类名，PascalCase** | `DialogueTool.gd` + `class_name DialogueTool`。本项目**不用**官方建议的 snake_case 文件名，因为文件名与类名一致才能全局搜到 |
| 用途后缀 | `*Def` 配置 / `*Entity` 运行时 / `*View` 展示 / `*Tool` 静态入口 / `*System` 调度 / `*Manager` 唯一实例 |
| 基类用短名 | `Def` / `Entity` / `UIPanel` / `Pool`；其余带领域前缀（`GoapAgent` / `ECSWorld`） |
| 测试脚本 | `test_<模块>.gd`（snake_case，`TestRunner` 按 `test_` 前缀扫描，唯一例外） |
| 引擎入口 | `plugin.gd`、`run_headless.gd` 保持小写（引擎约定） |

### 目录

PascalCase，与模块名一致：`Dialogue/`、`Core/`、`ArrayView/`。内部层 `Def/ Entity/ View/ Tool/ Editor/`。

### 场景与资源

| 类型 | 规则 | 例 |
|---|---|---|
| 场景 | PascalCase | `RankView.tscn`、`GameRoot.tscn` |
| 演示场景 | `*Demo.tscn`，可直接运行 | `DialogueDemo.tscn` |
| 演示脚本 | 与场景同目录同名 | `Scenes/Dialogue/DialogueDemo.gd` |
| 资源 `.tres` | snake_case | `stat_damage.tres`、`tut_welcome.tres` |

### 方法

| 形 | 义 |
|---|---|
| `_foo()` | 引擎 / 宿主回调 |
| `on_xxx` | 信号，过去式 = 完成态 |
| `get_` / `is_` / `has_` | 纯读与谓词，无副作用 |
| `apply` / `revert` | 可逆效果，必须成对 |
| `await_*` | 协程，返回结果或 `false`，禁止 `void` |

返回约定：`bool` = 是否生效；`void` = 已受理；`Error` = 仅 IO；`null` = 查询未命中。

## 五、三种合法协作

1. **继承扩展**：项目 `extends` 框架基类（`DamageEffectDef extends EffectDef`）
2. **组合调用**：项目调框架工具（`SaveTool.save_async`）
3. **鸭子回调**：框架侧参数不带类型，或项目注入 `Callable`。框架永不 `load` 项目脚本

## 六、红线

| # | 禁止 |
|---|---|
| 1 | 框架代码出现项目资源路径默认值 |
| 2 | 框架类型注解 / 导入项目类 |
| 3 | 游戏策略（联机权限、存档格式）写死在框架里 |
| 4 | 框架注释用项目专属类名举例 |

口诀：**路径、类型名、策略、注释，四处都不要让框架认识项目。**

## 七、搬迁纪律

改目录 / 改名时：

1. `git mv`，`.gd` 与同名 `.uid` 一起移
2. 替换**所有**引用：不止 `.gd` —— `plugin.gd` 里有 `.tscn` / `.png`，`project.godot` 里有 autoload 路径
3. 跑 `test_framework_compile`：`test_all_framework_paths_exist` 会扫描所有 `res://addons/DEVFramework/...` 并断言文件存在

**不要移动**：`Native/`（二进制 + 写死的库路径）、`MCP/`（preload 硬编码网）。
