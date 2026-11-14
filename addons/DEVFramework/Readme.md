# DEVFramework

Godot 4.7 数据驱动框架：`Def`（静态配置）→ `Entity`（运行时）→ `View`（显示），配一批静态 Tool 与一个内置 MCP 调试服务器。

- **框架 = 机制，项目 = 内容**：换一款游戏仍成立的进框架，玩法语义留在项目。边界规则见 [LAYERS.md](LAYERS.md)。
- **Def 只描述配置**，不存运行时状态；运行时数据在 Entity / Component / 节点上。

## 安装

1. 复制 `addons/DEVFramework/` 到项目 `addons/`，在插件面板启用。
2. 菜单 **项目 → 工具 → 创建 DEV 项目结构** 生成 `Assets/Def/`、`Scenes/`、`Scripts/{Def,Entity,View}/` 骨架。

C++ 原生能力（ECS）需编译，见 [gdextension/README](../../gdextension/README.md)。

## 三层

| 层 | 基类 | 职责 |
|---|---|---|
| Def | `Def`(Resource) | 策划配置的 `.tres`：名称 / 翻译 / 存档路径 |
| Entity | `Entity`(RefCounted)、`Entity2D`/`Entity3D`(Node) | 运行时数据载体，由 Def 驱动 |
| View | `UIPanel` / `ArrayView` / … | 只负责显示，`data` 变化即刷新 |

**Def 家族**：`EntityDef`、`ConditionDef`、`EffectDef`（`apply`/`revert`）、`ValueDef`（`get_float`）、`SignalDef`（`connect/disconnect`）。组合这些就能在编辑器里搭出效果与数值表达式。

```gdscript
@tool
class_name DamageEffectDef extends EffectDef
@export var value: ValueDef
func apply(ctx) -> void:
	ctx.damage = value.get_int(ctx)
```

**Entity 家族**：`Modifier` / `ModifierValue`（base + 修饰链，`value` 只读，改 `base_value` 或 `add_modifier`）、`StateMachine`（异步转换、guard/enter/exit）。

挂在实体下的逻辑用**普通 Node**（需要实体就 `@export var entity: Entity2D` 或 `get_parent() as Entity2D`），框架不再提供"节点组件"基类。

`def` 是鸭子约定：子类自己声明 `var def: XxxDef`，`Entity.new(some_def)` 才能注入。

## Tool（全部静态类）

| 分类 | 类 |
|---|---|
| 日志 / 存档 | `LogTool`（标签 + 计时）、`SaveTool`（JSON/GZIP、`.bak` 回退、merge、版本迁移、`load_defs`） |
| 异步 | `AsyncTool`（`load_resource_async` / `thread_call` / `await_until` / `call_in_frames` / `await_with_timeout` / `await_coroutine`） |
| 输入 / 时间 | `InputTool`（模式切换、焦点组、InputMap 持久化）、`TimeTool`（基础速度 + keyed 倍率 + 暂停） |
| 步进 | `TickTool.defer(order_key, action)` + 宿主每物理帧末 `tick()`；`GameTimer` |
| 文本 | `TranslationTool` / `CSVDataAccess` / `TipTool` |
| 生命周期 | `NodeTreeTool`（按约定调 `game_init` / `game_ready` / `save_data` / `load_data`） |
| 音频 | `AudioTool`（常驻复音通道、3D 定位）、`AudioMixerTool`（效果预设 + 总线）、`AudioBakeTool`（录音 + WAV） |
| UI | `UITool`（6 层栈）、`UIPanelTool`（2D/3D 共用状态机）、`ArrayViewTool` |
| 其它 | `CameraTool` / `ChangelogTool` / `DisplayTool` / `FileTool` / `PointerTool` / `PrewarmTool` / `ScreenshotTool` |

项目设置项（插件注册时写入）：`dev_framework/log/*`（开关、时间戳、忽略标签）、`save_tool/encrypt_salt`、`lightmap/scan_dir`、`mcp/*`（见下文 MCP 一节）。

## View

- `UIPanel` / `UIPanel3D`：`open` / `close` / `toggle` / `popup` / `await_closed`，信号 `on_open` / `on_opened` / `on_close` / `on_closed`，可覆写 `_back()` / `_focus_enter()` / `_focus_exit()`。
- `UITool` 六层：`BACKGROUND` / `HUD` / `PANEL` / `DIALOG`（同层互斥）/ `TOOLTIP`（单实例）/ `TOP`；`back()` 只处理 DIALOG 与 PANEL。
- 数组视图：`ArrayView`（流式）、`SlotArrayView2D/3D`（固定槽）、`OffsetArrayView2D/3D`（按 offset 排列）。填 `pool_key` + `pool_size` 走对象池（`Pool` / `PoolService`），归还时自己清 `data`、断信号。
- 渲染：`OutlineEffect`、`GLSLShaderEffect`、`Trail3D`、`BakedMeshInstance3D`（资源级光照贴图）、`SubView3D`、`ShaderProgressBar`。

**约定：UI 一律用 `.tscn` 搭，不代码生成。**

## 模块

| 模块 | 文档 |
|---|---|
| ECS（C++ 列存储 + 系统 + 查询链 DSL） | [ECS/Readme.md](ECS/Readme.md) |
| 3D 镜头（机位竞争 + 混合 + 冲击） | [Camera/Readme.md](Camera/Readme.md) |
| 任务 / 教程 | [Task/Readme.md](Task/Readme.md) |
| GOAP AI | [AI/Readme.md](AI/Readme.md) |
| 命令回放 | [GameCommand/Readme.md](GameCommand/Readme.md) |

## MCP 调试服务器

插件启用即监听 `http://127.0.0.1:9988/mcp`（所有项目共用这一个端口）。

- 同时开多个项目时先 `list_instances`，用 `use_instance` 选默认目标，或给单次调用带 `instance`。
- 默认目标跨重启保留；目标不在线时直接报错，不会改到别的项目。
- 每条工具结果末尾会带一行 `[target: 项目@哈希 (路径)]`，用来确认这次究竟落在哪个项目。
- 常用工具：`validate`、`get_logs`、`eval_code`、`get_scene_tree`、`set_node_property`、`create_resource`、`run_tests`、`game_control`、`restart_editor`。
- 导出包默认不带 MCP 入口（`dev_framework/mcp/runtime_enabled = false`）。

## 引擎陷阱

1. **改框架代码后必须重启编辑器**（`restart_editor`）：已注册的全局类不会真正 reload，行为与源码不符且无提示。
2. `await` 已完成的协程句柄会永久挂起 → 用 `AsyncTool.await_coroutine`。
3. 脚本 reload 后，跨编译代次的类型化赋值可能静默得到 null → 跨边界传对象用无类型变量。
4. `can_instantiate()` 对 `RefCounted` 全局类可能误报 false → 直接 `new()` 判空。

## 存档与翻译

- Def 存档只存**相对 `res://Assets/Def/` 的路径**，DLC 靠同路径覆盖资源；纪律见 [LAYERS.md](LAYERS.md) §七。
- 在编辑器改 `tr_name` 等属性会自动写回 `Assets/Translation/*.csv`（Def 子类需 `@tool`）。
