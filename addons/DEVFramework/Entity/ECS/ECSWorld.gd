class_name ECSWorld
extends RefCounted

## ECS 世界 —— 用户主入口。持有 C++ 核心(ECSCore), 提供:
##   - 组件注册 / 实体创建与销毁
##   - 系统注册与按优先级调度(tick)
##   - 批量查询与列访问(高频路径)
##   - 批量事件队列(替代信号风暴)
##
## 用法:
##   var world = ECSWorld.new()
##   world.register_component(HealthComponent)      # 自动反射 schema
##   var e = world.create_entity()
##   world.add_component(e, HealthComponent)
##   world.register_system(HealSystem.new())        # ECSSystem 子类
##   world.tick(delta)                              # 每帧调用(或挂 ECSTick Node)

# ---------------- 核心句柄 ----------------
var _core: Object = null                 # ECSCore 原生实例
var _available: bool = false

# ---------------- 组件注册表 ----------------
var _component_registered := {}          # Script -> bool (避免重复注册)
var _component_names := {}               # Script -> StringName
var _components: Array[Script] = []

# ---------------- 系统调度 ----------------
var _systems: Array[ECSSystem] = []
var _system_priorities: Array[int] = []
var _system_before: Array = []   # 每系统: 必须在其后执行的系统引用数组
var _system_after: Array = []    # 每系统: 必须在其前执行的系统引用数组
var _sorted: Array[ECSSystem] = []
var _dirty_schedule := true

# ---------------- 事件队列 ----------------
var _event_queues := {}                  # type(StringName) -> Array[Variant]
var _event_subscribers := {}             # type(StringName) -> Array[Callable]

func _init(use_shared_core: bool = true) -> void:
	# 默认使用全局共享核心(游戏通常只有一个世界);
	# 需要多个隔离世界(如性能对比/沙盒)时传 false 创建独立核心。
	if use_shared_core:
		_core = ECSNative.get_instance()
	else:
		_core = ClassDB.instantiate(&"ECSCore")
	_available = _core != null

## 原生层是否可用(不可用时所有操作静默失败)
func is_native_available() -> bool:
	return _available

## 原生实例(高级用法直接调用)
func native() -> Object:
	return _core

# ============================================================
#  组件注册
# ============================================================

## 注册组件类(ECSComponent 子类)。重复注册幂等。
## 通过当前世界自己的 _core 注册(不依赖全局单例)。
func register_component(component_class: Script) -> bool:
	if not _available:
		return false
	if _component_registered.get(component_class, false):
		return true
	var probe: Variant = ECSNative.instantiate_script(component_class)
	if probe == null:
		return false
	var schema: Dictionary = probe.get_schema()
	var fields: Array = schema.get("fields", [])
	var fnames := PackedStringArray()
	var ftypes := PackedInt32Array()
	var fdefaults: Array = []
	for f in fields:
		fnames.append(f.name)
		ftypes.append(f.type)
		fdefaults.append(f.default)
	var name: StringName = schema.get("name", &"")
	if name == &"":
		return false
	if _core.call(&"register_component", name, fnames, ftypes, fdefaults) < 0:
		return false
	_component_registered[component_class] = true
	_component_names[component_class] = name
	_components.append(component_class)
	return true

## 返回组件类名(StringName)
func component_name(component_class: Script) -> StringName:
	return _component_names.get(component_class, &"")

## 已注册组件类列表
func registered_components() -> Array[Script]:
	return _components

# ============================================================
#  实体
# ============================================================

## 创建实体, 返回实体 id(int32: index|version<<24)
func create_entity() -> int:
	return _core.create_entity() if _available else -1

func is_alive(entity: int) -> bool:
	return _available and _core.is_alive(entity)

## 销毁实体(从所有组件移除, 复用 id 防悬垂)
func destroy_entity(entity: int) -> void:
	if _available:
		_core.destroy_entity(entity)

## 给实体附加组件。component 传 ECSComponent 子类或已注册类名。
func add_component(entity: int, component, def_data: Dictionary = {}) -> bool:
	if not _available:
		return false
	var name := _resolve_component_name(component)
	if name == &"":
		return false
	if not _core.add_component(entity, name):
		return false
	# 附加后用 def_data 覆盖默认值(可选, 数据驱动兼容)
	for k in def_data:
		_core.set_field(entity, name, StringName(k), def_data[k])
	return true

func has_component(entity: int, component) -> bool:
	if not _available:
		return false
	var name := _resolve_component_name(component)
	return name != &"" and _core.has_component(entity, name)

func remove_component(entity: int, component) -> void:
	if not _available:
		return
	var name := _resolve_component_name(component)
	if name != &"":
		_core.remove_component(entity, name)

func _resolve_component_name(component) -> StringName:
	if component is Script:
		var n: StringName = _component_names.get(component, &"")
		if n != &"":
			return n
		# 未注册: 尝试从 resource_path 稳定获取类名
		var probe: Variant = ECSNative.instantiate_script(component)
		if probe != null:
			return probe.get_schema().name
		return &""
	if component is StringName or component is String:
		return StringName(component)
	return &""

# ============================================================
#  字段访问(低频: 单实体)
# ============================================================

func get_field(entity: int, component, field: StringName):
	return _core.get_field(entity, _resolve_component_name(component), field)

func set_field(entity: int, component, field: StringName, value) -> void:
	_core.set_field(entity, _resolve_component_name(component), field, value)

# ============================================================
#  批量查询与列访问(高频: 系统内)
# ============================================================

## 查询匹配实体(返回全局行号列表)。
## anchor/must/without 传组件类名或 Script。
## 行号可直接索引 get_column 返回的任意组件列 —— 跨组件对齐, 零转换。
## 需要实体 ID 时用 entity_of_row() 转换。
func query_rows(anchor, must: Array = [], without: Array = []) -> PackedInt32Array:
	if not _available:
		return PackedInt32Array()
	var anchor_name := _resolve_component_name(anchor)
	if anchor_name == &"":
		return PackedInt32Array()
	var must_names := PackedStringArray()
	for m in must:
		must_names.append(_resolve_component_name(m))
	var without_names := PackedStringArray()
	for w in without:
		without_names.append(_resolve_component_name(w))
	return _core.query_rows(anchor_name, must_names, without_names)

## 取整列数据(返回 Packed 数组拷贝, 按行号索引)。
func get_column(component, field: StringName):
	if not _available:
		return null
	return _core.get_column(_resolve_component_name(component), field)

## 整列写回。
func set_column(component, field: StringName, values) -> void:
	if _available:
		_core.set_column(_resolve_component_name(component), field, values)

# ---- Tier 0: 原生批量运算(纯 C++ 循环, 无 GDScript 解释开销) ----

## 批量数值变换(anchor 组件中同时拥有 must 的实体, 对 op 字段原地运算)。
## op: 0=ADD(col+=addend), 1=MUL_ADD(col=col*factor+addend), 2=SET(col=addend), 3=CLAMP(见 batch_clamp)
func batch_apply(anchor, must: Array, op_comp, op_field: StringName, op: int, factor: float, addend: float) -> int:
	if not _available:
		return 0
	return _core.batch_apply(_resolve_component_name(anchor), _names(must),
		_resolve_component_name(op_comp), op_field, op, factor, addend)

## 批量边界钳制: col = clamp(col, min, max), min/max 取自其他组件字段
func batch_clamp(anchor, must: Array, op_comp, op_field: StringName, min_comp, min_field: StringName, max_comp, max_field: StringName) -> int:
	if not _available:
		return 0
	return _core.batch_clamp(_resolve_component_name(anchor), _names(must),
		_resolve_component_name(op_comp), op_field,
		_resolve_component_name(min_comp), min_field,
		_resolve_component_name(max_comp), max_field)

## 批量向量积分: pos += vel * delta (Vector2/3)
func batch_vec_add(anchor, must: Array, pos_comp, pos_field: StringName, vel_comp, vel_field: StringName, delta: float) -> int:
	if not _available:
		return 0
	return _core.batch_vec_add(_resolve_component_name(anchor), _names(must),
		_resolve_component_name(pos_comp), pos_field,
		_resolve_component_name(vel_comp), vel_field, delta)

func _names(arr: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for a in arr:
		out.append(_resolve_component_name(a))
	return out

## 行号 -> 实体 id。
func entity_of_row(component, row: int) -> int:
	return _core.entity_of_row(_resolve_component_name(component), row) if _available else -1

## 拥有某组件的实体总数。
func count(component) -> int:
	if not _available:
		return 0
	return _core.count_entities(_resolve_component_name(component))

# ============================================================
#  系统
# ============================================================

## 注册系统。priority 越大越先执行。
## before/after: 依赖声明的系统引用数组(该系统须在 after 之后、before 之前执行)。
func register_system(system: ECSSystem, priority: int = 0, before: Array = [], after: Array = []) -> void:
	if system == null or _systems.has(system):
		return
	# 系统内所需的组件必须在注册前已注册
	for comp in system.required_components():
		register_component(comp)
	_systems.append(system)
	_system_priorities.append(priority)
	_system_before.append(before)
	_system_after.append(after)
	_dirty_schedule = true

func remove_system(system: ECSSystem) -> void:
	var i := _systems.find(system)
	if i >= 0:
		_systems.remove_at(i)
		_system_priorities.remove_at(i)
		_system_before.remove_at(i)
		_system_after.remove_at(i)
		_dirty_schedule = true

## 每帧驱动全部系统。内部先按依赖图拓扑排序(优先级仅作同层平级次序)。
func tick(delta: float) -> void:
	if not _available:
		return
	_resort()
	var ctx := ECSSystemContext.new(self)
	for system in _sorted:
		if not system.enabled:
			continue
		system._run(ctx, delta)
	_dispatch_events()

## 依赖图拓扑排序: 满足 before/after 约束, 同层按优先级降序。
## 依赖冲突(环)时优先保留 priority 更高者, 弱化为无约束。
func _resort() -> void:
	if not _dirty_schedule:
		return
	_sorted.clear()
	_dirty_schedule = false
	if _systems.is_empty():
		return

	# 1) 建立 "系统 -> 其前置集合(必须先于它执行)" 映射
	var n := _systems.size()
	var prerequisites: Array = []  # 每项: Array[ECSSystem] 必须在其之前
	prerequisites.resize(n)
	for i in n:
		var pre: Array = []
		for other in _system_after[i]:
			if other != null and _systems.has(other):
				pre.append(other)
		# before[b] = x 表示 x 必须在 b 之前 => 对 x 而言 b 是其 after
		for j in n:
			if _system_before[j].has(_systems[i]):
				pre.append(_systems[j])
		prerequisites[i] = pre

	# 2) Kahn 拓扑排序(每次取"前置全满足且优先级最高"者)
	var done := {}
	var result: Array = []
	while result.size() < n:
		var best := -1
		for i in n:
			if done.has(i):
				continue
			var ready := true
			for pre in prerequisites[i]:
				if not done.has(_systems.find(pre)):
					ready = false
					break
			if not ready:
				continue
			if best == -1 or _system_priorities[i] > _system_priorities[best]:
				best = i
		if best == -1:
			# 依赖环: 取剩余中优先级最高者强制执行, 破坏环
			for i in n:
				if done.has(i):
					continue
				if best == -1 or _system_priorities[i] > _system_priorities[best]:
					best = i
		done[best] = true
		result.append(_systems[best])
	_sorted.clear()
	for s in result:
		_sorted.append(s)

# ============================================================
#  批量事件(替代信号风暴: 帧内累积, 帧末一次性派发)
# ============================================================

## 投递事件(帧末统一派发给订阅者)。
func emit_event(type: StringName, payload = null) -> void:
	if not _event_queues.has(type):
		_event_queues[type] = []
	_event_queues[type].append(payload)

## 订阅事件。handler(payload)。
func on_event(type: StringName, handler: Callable) -> void:
	if not _event_subscribers.has(type):
		_event_subscribers[type] = []
	_event_subscribers[type].append(handler)

func off_event(type: StringName, handler: Callable) -> void:
	var arr: Array = _event_subscribers.get(type, [])
	arr.erase(handler)

func has_pending_events(type: StringName) -> bool:
	return _event_queues.has(type) and not _event_queues[type].is_empty()

## 待派发事件总数(帧末统计用)
func pending_event_count() -> int:
	var total := 0
	for type in _event_queues:
		total += (_event_queues[type] as Array).size()
	return total

## 订阅某事件的处理器数量
func subscriber_count(type: StringName) -> int:
	return (_event_subscribers.get(type, []) as Array).size()

func _dispatch_events() -> void:
	for type in _event_queues:
		var queue: Array = _event_queues[type]
		if queue.is_empty():
			continue
		var handlers: Array = _event_subscribers.get(type, [])
		for payload in queue:
			for h in handlers:
				h.call(payload)
		queue.clear()

# ============================================================
#  序列化/存档 (对接 SaveTool)
# ============================================================

## 序列化整个世界的组件数据 → Dictionary, 可交给 SaveTool.save_data 存档。
func serialize() -> Dictionary:
	return _core.serialize() if _available else {}

## 反序列化: 重建实体与数据。
## 返回 Array[int]: 新建实体的真实实体 ID 列表(用它绑定 ECSNode 等)。
## 注意: 组件需先 register_component(名称一致)再调用。
func deserialize(data: Dictionary) -> Array:
	return _core.deserialize(data) if _available else []

## 内存统计(调试)
func debug_stats() -> Dictionary:
	return _core.debug_stats() if _available else {}
