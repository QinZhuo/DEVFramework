# DEVFramework ECS 使用说明

本文档说明 `addons/DEVFramework/ECS/` 高性能 ECS 框架的完整使用方法。

**架构**：C++ GDExtension（`ECSCore`，SoA 列存储 / 稀疏集 / 签名视图 / 批量运算 / SIMD / 持久线程池）+ GDScript 封装层（`ECSWorld` / `ECSSystem` / 规则 DSL）。**框架强依赖原生库**（`devecs.gdextension`），缺失会明确报错，无回退。

**定位**（与场景节点配合的三种用法）：
- **海量实体**（1 万+）：纯 ECS 数据 + 渲染直读列，不建 Node。
- **关键实体**（玩家/NPC/Boss）：`Component` 桥接实体与场景节点。
- **数值逻辑**：规则 DSL / `process` 回调在系统内批量执行。

---

## 目录

1. [快速开始](#一快速开始)
2. [组件定义](#二组件定义)
3. [实体与组件操作](#三实体与组件操作)
4. [系统与统一查询链](#四系统与统一查询链)
5. [规则层 DSL（C++ batch 执行）](#五规则层-dslc-batch-执行)
6. [process 回调（手写层）](#六process-回调手写层)
7. [查询](#七查询)
8. [批量列访问](#八批量列访问)
9. [系统并行调度](#九系统并行调度)
10. [命令缓冲](#十命令缓冲)
11. [生命周期钩子与变化检测](#十一生命周期钩子与变化检测)
12. [事件](#十二事件)
13. [Prefab 与序列化](#十三prefab-与序列化)
14. [Component 场景桥接](#十四ecsnode-场景桥接)
15. [性能架构速览](#十五性能架构速览)

---

## 使用层次（先看入门，再按需进阶）

| 层次 | 章节 | 说明 |
|---|---|---|
| **① 入门**（90% 场景） | 快速开始 / 组件定义 / 实体操作 / 系统与查询链 / 规则层 DSL / process 回调 / Component | 定义组件 → 建实体 → 写系统（`for_each` 查询链）→ tick 驱动。**大多数需求到这里就够了** |
| **② 进阶** | 查询 / 批量列访问 / 命令缓冲 / Prefab 与序列化 | 数据查询、批量读写、结构变更、存档 |
| **③ 高级**（性能/机制） | 系统并行调度 / 生命周期钩子与变化检测 / 事件 | 并行、实体生命周期、事件驱动 |

> 规则：**普通开发者只走查询链（`for_each` → 动作）**。`batch_*`、`query_aligned*`、`borrow/return_columns` 等是底层原生 API（性能层），已由规则 DSL / `process` 封装，仅在需要极致控制时直接使用。

---

## 实体体系选择（Entity / Entity2D·3D / Component）

框架有两种"实体/组件"写法, 按场景选:

| 类 | 基类 | 职责 | 何时用 |
|---|---|---|---|
| **`Entity`** | RefCounted | 纯数据实体(内建 `ecs` 桥接, 数据放 ECS 列) | 轻量数据/逻辑实体(Buff/Modifier/纯数据) |
| **`Entity2D`/`Entity3D`** | Node2D/Node3D | 节点实体(ECS 实体 + 场景表现 + 位置同步) | 需要场景节点的实体(角色/子弹/单位) |
| **`Component`** | Node | 表现/交互补充(挂 Entity2D/3D 下, 补充其 ECS 数据) | 给实体挂附加功能, 需场景节点 |
| **ECS 体系** | — | 纯数据逻辑(`ECSWorld`/`ECSComponent`/`ECSSystem`/`ECSQuery`) | 海量数据、批量逻辑, 不直接面向对象 |

```gdscript
# 只有数据 → Entity
var e := Buff.new()
e.ecs.world = world
e.add_component(ECSAttribute, {"hp": 100})

# 需要场景表现 → Entity2D
var unit := Entity2D.new()
unit.world = world
unit.add_component(MoveComponent, {"pos": Vector2.ZERO})
unit.bind_pos(MoveComponent, &"pos")
get_tree().current_scene.add_child(unit)

# 挂载补充功能 → Component(须挂 Entity2D/3D 下)
unit.add_child(MyPowerComp.new())
```

> **组件二义提醒**：`Component`(Node 表现补充) 与 `ECSComponent`(纯数据 schema) 不同——数据用 `ECSComponent` + `add_component`, 表现/交互补充用 `Component` 挂节点。

### 传统写法即 ECS（属性自动路由，路线 A）

挂 `Entity2D`/`Entity3D`（或挂 `Component` 到其下）并设置 `world` 后，**直接读写 schema 字段自动进 ECS**，无需显式调 `ecs.set_field`：

```gdscript
class_name Health extends ECSComponent
@export var max_hp := 100
@export var hp := 100

# 先注册组件（现有要求）
my_world.register_component(Health)

# 传统写法（节点脚本里）
unit.hp = 80            # → 自动附加 Health 并写 ECS 列
var v := unit.max_hp    # ← 从 ECS 列读
```

- **自动附加**：第一次写某组件字段时，若实体尚无该组件则自动附加（用 schema 默认值）。
- **Component 补充**：`comp.max_hp = 200` 同样路由宿主实体。
- **懒加载保持**：不设 `world`/不触碰 schema 字段 → `ecs` 不创建、零开销；设了 world 后属性读写成为新的触发点。
- **注意**：schema 字段名**勿与 Node 原生属性重名**（`position`/`visible` 等，重名走原生属性不进 ECS）；组件需先 `register_component` 且 `world` 已设置，否则 `_set` 不接管、按 Godot 原生规则（未声明属性赋值会报错）。

---

## 一、快速开始

```gdscript
# 创建世界（默认共享全局核心；多世界隔离传 false）
var world := ECSWorld.new()

# 注册组件（自动反射 @export 字段为 schema）
world.register_component(HealthComponent)

# 创建实体并附加组件
var e := world.create_entity()
world.add_component(e, HealthComponent)
world.set_field(e, HealthComponent, &"hp", 50)

# 注册系统（priority 越大越先执行）
world.register_system(HealSystem.new(), 10)

# 每帧驱动（可挂 ECSTick 节点自动驱动）
world.tick(delta)
```

`ECSTick` 节点：挂在任意场景节点，`ecs_tick.world = world`，自动每帧 `tick`。

---

## 二、组件定义

组件是**纯数据 schema**，继承 `ECSComponent`（Resource），用 `@export` 声明字段：

```gdscript
class_name HealthComponent extends ECSComponent

@export var max_hp: int = 100
@export var hp: int = 100
@export var regen: float = 2.0
```

- 注册时自动反射字段（`register_component`），运行时数据实际存在 C++ SoA 列中。
- 支持字段类型：`int` / `float` / `bool` / `Vector2` / `Vector3` / `Vector4` / `Color` / `String`。
- 组件实例本身也可作为 `.tres` 子资源配置（Prefab 用）。

---

## 三、实体与组件操作

实体 ID 是 `int`（内部 `index | version<<24`，复用防悬垂）。

| 操作 | API |
|---|---|
| 创建 / 销毁实体 | `create_entity()` / `destroy_entity(e)` |
| 附加 / 移除组件 | `add_component(e, Comp)` / `remove_component(e, Comp)` |
| 判断拥有组件 | `has_component(e, Comp)` |
| 读 / 写单实体字段 | `get_field(e, Comp, &"hp")` / `set_field(e, Comp, &"hp", v)` |
| 是否存活 | `is_alive(e)` |
| 拥有某组件实体数 | `count(Comp)` |

> 系统内的结构变更（创建/销毁/加删组件）请用命令缓冲（见[十](#十命令缓冲)），避免遍历中改结构。

---

## 四、系统与统一查询链

系统继承 `ECSSystem`，实现 `_run(ctx, delta)`。**所有逻辑走统一查询链 `ctx.for_each(...)`**，与规则层同一套构建器。

```gdscript
class_name HealSystem extends ECSSystem

func required_components() -> Array[Script]:
	return [HealthComponent]

func _run(ctx: ECSSystemContext, delta: float) -> void:
	# 与声明规则完全相同的查询链（C++ batch 执行），链尾无需 execute(系统 _run 结束自动执行); 需要立即结果时可显式 .execute()
	ctx.for_each(HealthComponent).where(&"hp").less_than(50).add(&"hp", 5.0 * delta * 60.0).execute()
```

**系统接口**：

| 成员 | 说明 |
|---|---|
| `required_components()` | 需要的组件（自动注册） |
| `read_components()` / `write_components()` | 读写声明（并行冲突检测 + 依赖排序用） |
| `can_run_parallel()` | 默认 true；访问场景树/节点须覆写 false（参考 `ECSSyncSystem`） |
| `_run(ctx, delta)` | 每帧逻辑 |

**三种动作模式**（同一查询链）：
- **标量动作**：`.add()/.sub()/.mul()/.div()/.set_value()` → C++ batch
- **列间动作**：`.add_from()/.set_from()/.clamp_where()` → C++ batch
- **回调动作**：`.process(cb)` → GDScript 灵活逻辑

`ECSSystemContext` 提供查询链入口 `for_each` 与低频 `get_field`/`set_field`/`emit_event`（底层列直连用 `ECSWorld.get_column`/`set_column`）。

---

## 五、规则层 DSL（C++ batch 执行）

`ECSQuery`（由 `ctx.for_each(Comp, must=[], without=[])` 创建）链式构建，**链尾必须 `.execute()`**。

### 标量动作

```gdscript
ctx.for_each(HealthComponent)
	.where(&"hp").less_than(50)   # 条件（AND，可多个）
	.add(&"hp", 10)               # hp += 10
	.mul(&"dmg", 1.5)             # dmg *= 1.5
	.div(&"cd", 2.0)              # cd /= 2
	.sub(&"cost", 5)              # cost -= 5
	.set_value(&"state", 1)       # state = 1
	.execute()
```

条件比较符：`less_than` / `less_or_equal` / `greater_than` / `greater_or_equal` / `equal` / `not_equal`。

### 列间动作（列与列联动）

```gdscript
# 列间动作参数顺序统一为 (目标字段, 源组件, 源字段)
# size = 8 + hp * 0.08（纯 C++）
ctx.for_each(BattleCell).set_from(&"size", BattleCell, &"hp", 0.08, 8.0).execute()

# dmg += atk
ctx.for_each(BattleCell).add_from(&"dmg", BattleCell, &"atk").execute()

# 仅 hp>0 的实体 hp = clamp(hp, min_hp, max_hp)（混合类型边界支持）
ctx.for_each(BattleCell).where(&"hp").greater_than(0).clamp_where(&"hp", BattleCell, &"min_hp", BattleCell, &"max_hp").execute()
```

| 动作 | 语义 |
|---|---|
| `add_from/sub_from(field, src, src_field)` | 目标列 `+= / -=` 源列 |
| `mul_from/div_from(field, src, src_field, factor)` | 目标列 `*= / /=` 源列（可乘 factor，除零跳过） |
| `set_from(field, src, src_field, factor, addend)` | 目标列 `= 源列*factor + addend` |
| `clamp_where(field, min_comp, min_field, max_comp, max_field)` | 满足条件时列钳制 |

`must`/`without` 过滤（组件匹配）：

```gdscript
ctx.for_each(Unit, [HealthComponent], [Dead])   # 有 Unit 且有 Health、无 Dead
```

---

## 六、process 回调（手写层）

复杂逻辑用 GDScript 回调。两种参数模式：

### A. 推荐写法：`.with(字段...)` 声明 + 回调直接收列参数

```gdscript
func _run(ctx: ECSSystemContext, _delta: float) -> void:
	# 声明要遍历的字段 → 回调按顺序直接收列(rows, hp, pos), 无字符串 key
	ctx.for_each(BattleCell).with([&"hp", &"pos"]).process(_battle_cb).execute()

func _battle_cb(rows: PackedInt32Array, hp: PackedFloat32Array, pos: PackedVector2Array) -> void:
	for r in rows:
		hp[r] -= 1
		pos[r] += Vector2(1, 0)
```

- `rows`：满足条件的行号；`hp`/`pos`：按 `.with` 声明顺序直接传入的列（borrow 独占引用，写无 COW）。
- 框架回调后**自动写回**，回调内零跨语言调用。

### B. 预拉列字典模式（跨组件多字段）

```gdscript
ctx.for_each(BattleCell).process(func(rows, data):
	var hp: PackedFloat32Array = data["BattleCell"]["hp"]   # data[组件类名][字段名]
	var atk: PackedFloat32Array = data["EnemyComp"]["atk"]
	for r in rows: hp[r] -= 1
, {BattleCell: [&"hp"], EnemyComp: [&"atk"]}).execute()
```

### C. 对齐行号模式（回调内手动取列写回）

```gdscript
ctx.for_each(BattleCell).process(_battle_cb2, [BattleCell]).execute()

func _battle_cb2(rows: PackedInt32Array, _comp_rows: Dictionary, w: ECSWorld) -> void:
	var hp: PackedFloat32Array = w.get_column(BattleCell, &"hp")
	for r in rows:
		hp[r] -= 1
	w.set_column(BattleCell, &"hp", hp)
```

- `comp_rows`：各组件对齐行号；回调内 `get_column` 取列 → 改 → `set_column` 写回（列是 COW 副本，改后必须写回）。

> 热路径请优先用规则动作（C++ batch），`process` 用于无法声明化的逻辑。

---

## 七、查询

```gdscript
# 行号查询（anchor 的 dense 行号，可直接索引 get_column 列）
var rows: PackedInt32Array = world.query_rows(HealthComponent, [MoveComponent], [Dead])

# 对齐行号：一次返回 anchor + 各 must 组件的对齐行号（免逐实体转换）
var aligned: Array = world.query_aligned(MoveComponent, [HealthComponent])
# aligned[0]=Move 行号, aligned[1]=Health 行号, 同一 k 索引各组件列

# 条件过滤 + 对齐（规则层内部用）
var filt: Array = world.query_aligned_where(Unit, [], [], [
	{"comp": Unit, "field": &"hp", "op": ECSWorld.CondOp.LESS_THAN, "value": 50}], [Unit, HealthComponent])
```

- 底层是**签名增量视图**（每签名维护实体列表，结构变更增量增删）→ 过滤查询 O(结果数)，实测 10 万实体过滤 1000 结果从 572µs 降到 21µs。
- 查询带**增量失效缓存**（同签名命中；`create_entity` 不失效、add/remove 只失效相关组件、destroy 全局失效）。

---

## 八、批量列访问（高级原生 API）

> 本章为**高级原生 API**。普通场景用 `process(cb, fields)` 预拉列 + 自动写回即可（见六），此处用于需要精细控制列内存的底层场景。

```gdscript
# 一次取多组件多列（1 次跨语言替代 N 次 get_column）
var cols: Dictionary = world.get_columns([
	{"comp": HealthComponent, "fields": [&"hp", &"max_hp"]},
	{"comp": MoveComponent, "fields": [&"pos"]}])
var hp: PackedFloat32Array = cols["HealthComponent"]["hp"]

# 一次写回多列
world.set_columns({"HealthComponent": {"hp": new_hp_array}})

# 借出列（独占引用，写无 COW；配 return 归还）
var data: Dictionary = world.borrow_columns(norm)
# ...改 data...
world.return_columns(data)
```

> `get_column`/`set_column` 单列仍可用；`borrow/return` 用于高频写路径避免 COW 深拷贝。

---

## 九、系统并行调度

默认开启，**自动生效**（无需配置）。首帧串行预热采集各系统访问组件，之后按冲突检测分批并行。

```gdscript
world.parallel_enabled = true        # 全局开关
world.parallel_threads = 0           # 0=自动(核数-1, 上限8)
world.parallel_min_systems = 2       # 至少 N 个系统才并行
```

- **冲突检测**：访问同一组件或有 before/after 依赖的系统自动串行，互不干扰的系统并行（C++ 持久 worker 池执行，免每帧建线程）。
- **顺序无关重排**：不可并行系统（屏障）不打断批，两侧无依赖的可并行系统仍可同批。
- **并行系统要求**：不访问场景树（需覆写 `can_run_parallel()=false`）；`read/write_components()` 声明准确；结构变更走命令缓冲。
- 调试：`world.is_parallel_active()` / `world.debug_parallel_stats()`。

---

## 十、命令缓冲

系统遍历中排队结构变更，帧末统一 flush（避免迭代失效 + 支持并行）：

```gdscript
var placeholder := world.cmd_create()              # 返回负占位句柄
world.cmd_add_component(placeholder, HealthComponent)
world.cmd_destroy(entity)
world.cmd_remove_component(entity, MoveComponent)
# world.tick() 帧末自动 cmd_flush()
```

---

## 十一、生命周期钩子与变化检测

```gdscript
# 组件获得/失去钩子（回调 func(entity: int)）
world.on_component_added(HealthComponent, _on_health_added)
world.on_component_removed(HealthComponent, _on_health_removed)
world.on_entity_destroyed(_on_entity_destroyed)
world.off_component_added(HealthComponent, _on_health_added)  # 取消

# 触发时机：立即 add/remove_component、destroy、命令缓冲 flush 后（主线程）
```

**变化检测**（组件级脏标记，写 API 自动标记本帧被写）：

```gdscript
world.is_component_dirty(HealthComponent)   # 本帧是否被 set_field/set_column/batch_* 写过
world.dirty_components()                    # 本帧被写过的组件列表
```

---

## 十二、事件

批量事件队列（帧内累积、帧末统一派发，替代信号风暴）：

```gdscript
world.emit_event(&"killed", {"entity": e, "data": ...})
world.emit_entity_event(&"killed", e, payload)

world.on_event(&"killed", _handler)                                  # func(payload)
world.on_entity_event(&"killed", [HealthComponent], _handler)        # func(entity_id, data)，按组件过滤
world.on_entity_event_where(&"killed", [HealthComponent], conditions, _handler)
```

---

## 十三、Prefab 与序列化

```gdscript
# 配置驱动（ECSPrefabDef 资源）→ prefab → 批量实例化
var ids: Array = world.spawn_from_def(crowd_def, 20000)   # 一次生成 2 万实体

# 手动构建 prefab
var prefab := world.create_prefab()
world.prefab_add(prefab, HealthComponent, {"hp": 100})
var ids2: Array = world.instantiate(prefab, 50, {HealthComponent: {"hp": 80}})

# 存档
var data := world.serialize()
SaveTool.save_data("user://save.dat", data, SaveTool.Mode.GZIP)
var restored: Array = world.deserialize(SaveTool.load_data("user://save.dat", SaveTool.Mode.GZIP))
```

---

## 十四、Component 场景桥接

关键实体（玩家/NPC）用 `Component` 桥接：

```gdscript
var view := Component.spawn(world, player_scene, Vector2(100, 200))
view.bind_pos(MoveComponent, &"pos")     # 位置绑定（ECSSyncSystem 批量同步）
view.add_component(HealthComponent)
view.set_field(HealthComponent, &"hp", 100)
view.sync_node_to_ecs()                  # 节点 → ECS（交互写回）
view.destroy()

# 注册位置同步系统（批量，优于 N 个 _process）
world.register_system(ECSSyncSystem.new(), 10)
```

`ECSSyncSystem` 遍历所有带 `NodeLink` 的实体批量搬运位置（`can_run_parallel()=false`，主线程）。

---

## 十五、性能架构速览

| 能力 | 实现 |
|---|---|
| 存储 | C++ SoA 列（Packed*Array）+ 稀疏集，实体 ID 复用防悬垂 |
| 查询 | 签名增量视图（O(结果数)）+ 增量失效缓存 |
| 数值逻辑 | 规则 DSL → C++ batch（SIMD FLOAT/INT/Vector2）+ 并行分片 |
| 跨语言 | `query_aligned`/`get_columns`/`set_columns`/borrow 一次拿多列 |
| 系统并行 | 冲突检测分批 + 顺序无关重排 + C++ 持久线程池 |
| 结构变更 | 命令缓冲（遍历中不直接改结构） |
| 编译 | `-march=native`（本机全部 SIMD 指令集） |

**性能实践建议**：
- 数值热点用规则 DSL（`add/sub/mul/div/add_from/set_from/clamp_where`）→ C++ batch。
- 高频写路径用 `borrow/return` 避免 COW；复杂逻辑用 `process(fields)` 预拉列 + 自动写回。
- 海量实体渲染直读列（参考 `ECSPointCloud`），关键实体用 `Component`。
- 并行系统声明好 `read/write_components()`，结构变更走 `cmd_*`。
