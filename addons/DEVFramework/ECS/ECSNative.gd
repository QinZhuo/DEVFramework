class_name ECSNative
extends RefCounted

## GDExtension 原生桥接 —— 懒加载 ECSCore(C++ 库)。
## 框架强依赖 C++ 原生库: 库缺失/版本不匹配时明确 push_error 报错(无静默回退)。
## 所有调用走动态 ClassDB 派发, 避免编辑器启动早期静态解析崩溃。
##
## 重要: 组件脚本一律通过 resource_path + load() 实例化, 不使用全局类名 .new()。
## 原因: 新加入的 class_name 脚本在 ClassDB 注册存在时序窗口, 全局类引用实例化
## 可能报 "Nonexistent function 'new' in base 'GDScript'", 而 load(path) 稳定可靠。

static var _inst: Object = null

static var _required_methods := [
	&"register_component", &"create_entity", &"is_alive", &"destroy_entity",
	&"add_component", &"has_component", &"remove_component", &"count_entities",
	&"query_rows", &"query_rows_aligned", &"query_rows_aligned_where", &"entity_of_row", &"get_field", &"set_field",
	&"get_column", &"set_column", &"get_columns", &"set_columns", &"borrow_columns", &"return_columns", &"get_entity_components",
	&"batch_apply_where", &"batch_count", &"batch_apply_col", &"batch_clamp_where",
	&"run_systems_parallel",
	&"create_prefab", &"is_prefab", &"prefab_add", &"instantiate", &"prefab_get_field",
]

## 获取原生实例(懒加载)。原生库不可用时 push_error 报错并返回 null(无静默回退)。
static func get_instance() -> Object:
	if _inst != null and is_instance_valid(_inst):
		return _inst
	if not ClassDB.class_exists(&"ECSCore"):
		push_error("ECSNative: ECSCore 类不存在! 请确认 devecs.gdextension 原生库已加载(框架强依赖 C++, 无回退)。")
		return null
	for m in _required_methods:
		if not ClassDB.class_has_method(&"ECSCore", m, false):
			push_error("ECSNative: ECSCore 缺少必需方法 %s! 请重新编译 devecs 原生库。" % m)
			return null
	_inst = ClassDB.instantiate(&"ECSCore")
	if _inst == null:
		push_error("ECSNative: ECSCore 实例化失败! 请检查 devecs.gdextension 配置。")
	return _inst

static func is_available() -> bool:
	return get_instance() != null

## 稳定实例化脚本: 通过 resource_path 加载并 new, 规避全局类注册时序问题。
## 若脚本处于半编译状态(can_instantiate()=false), 主动 reload() 强制编译后再 new。
## 返回实例或 null。
static func instantiate_script(component_class: Script) -> Variant:
	if component_class == null:
		return null
	var path: String = component_class.resource_path
	if path == "":
		return null
	var script: Variant = load(path)
	if script == null:
		return null
	if not script.can_instantiate():
		script.reload()  # 强制编译: 修复首次加载半编译竞态
	return script.new()

## 注册组件: 反射 component_class 的 schema(统一走 collect_schema)。
## 成功返回组件类名(StringName), 失败返回空 StringName。
static func register(component_class: Script) -> StringName:
	var inst := get_instance()
	if inst == null:
		return &""
	var probe: Variant = instantiate_script(component_class)
	if probe == null:
		return &""
	var schema: Dictionary = collect_schema(probe)
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
		return &""
	var r: int = inst.call(&"register_component", name, fnames, ftypes, fdefaults)
	if r < 0:
		return &""
	return name

## 强制重新检测(清空缓存实例)
static func refresh() -> void:
	_inst = null


## —— 统一字段反射工具 ——
## 所有"把对象的 @export/脚本变量当作组件数据"的地方(get_schema / register_component /
## build_prefab / Entity2D.register_to_ecs)都走这里, 保证反射条件一致。

## 统一反射条件: 脚本变量(SCRIPT_VARIABLE) + 非 getter/setter(纯数据) + 可选 @export。
static func _is_data_field(p: Dictionary, require_export: bool) -> bool:
	if not (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
		return false
	if p.get("getter", "") != "" or p.get("setter", "") != "":
		return false
	if require_export and not (p.usage & PROPERTY_USAGE_EDITOR):
		return false
	return true


## 收集实例的纯数据字段 schema: {name, fields:[{name, type, default}]}
## require_export=true 时只收集 @export 字段(普通 Node 脚本用它区分数据字段与显示/配置字段);
## false 时收集全部脚本纯变量(ECSComponent 子类, 其字段均为数据)。
static func collect_schema(instance, require_export: bool = false) -> Dictionary:
	var fields := []
	for p in instance.get_property_list():
		if _is_data_field(p, require_export):
			fields.append({"name": p.name, "type": p.type, "default": instance.get(p.name)})
	var s: Script = instance.get_script()
	return {"name": s.get_global_name() if s != null else &"", "fields": fields}


## 收集实例当前各数据字段的值: {field_name: value}
static func collect_values(instance, require_export: bool = false) -> Dictionary:
	var values := {}
	for p in instance.get_property_list():
		if _is_data_field(p, require_export):
			values[p.name] = instance.get(p.name)
	return values
