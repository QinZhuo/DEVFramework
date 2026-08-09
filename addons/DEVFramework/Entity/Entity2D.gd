class_name Entity2D extends Node2D

## 2D 节点实体 —— ECS 实体 + Node2D 场景表现 + 可挂 Component 补充。
##
## 数据在 ECS 列, 本节点是门面/表现。位置可用 bind_pos 同步 ECS↔节点。
## 用法:
##   var e := Entity2D.new()
##   e.world = my_world
##   e.add_component(HealthComponent, {"hp": 100})   # 数据进 ECS 列
##   e.bind_pos(MoveComponent, &"pos")               # 位置同步
##   e.sync_ecs_to_node()
##   # 挂 Component 子节点补充功能
##   e.add_child(SomeComponent.new())

## ECS 桥接(数据在 ECS 列, 懒创建 —— 只有用到 ecs 时才实例化)
var _ecs: ECSLink = null
var ecs: ECSLink:
	get:
		if _ecs == null:
			_ecs = ECSLink.new()
		return _ecs
	set(v):
		_ecs = v

## 便捷访问
var world: ECSWorld:
	get:
		return ecs.world
	set(v):
		ecs.world = v

var entity_id: int:
	get:
		return ecs.entity_id
	set(v):
		ecs.entity_id = v

# ---- 位置同步 ----
var _pos_comp: Script = null
var _pos_field: StringName = &"pos"
var _pos_use_xy: bool = false
var _x_field: StringName = &"x"
var _y_field: StringName = &"y"


func _exit_tree() -> void:
	ecs.destroy()


## —— ECS 实体门面(便捷) ——

func add_component(comp: Script, values: Dictionary = {}) -> bool:
	return ecs.add_component(comp, values)


func has_component(comp) -> bool:
	return ecs.has_component(comp)


func get_field(comp, field: StringName):
	return ecs.get_field(comp, field)


func set_field(comp, field: StringName, value) -> void:
	ecs.set_field(comp, field, value)


func is_bound() -> bool:
	return ecs.is_bound()


func destroy() -> void:
	ecs.destroy()


## 记录 NodeLink(供 ECSSyncSystem 批量同步位置)。需先 world/entity_id 就绪。
func attach_node_link() -> void:
	if ecs.world == null or ecs.entity_id < 0:
		return
	ecs.world.register_component(NodeLink)
	if ecs.add_component(NodeLink):
		ecs.set_field(NodeLink, &"node_path", get_path().get_concatenated_names())
		if _pos_comp != null:
			ecs.set_field(NodeLink, &"pos_component", _pos_comp.get_global_name())
			ecs.set_field(NodeLink, &"pos_field", str(_pos_field))
			ecs.set_field(NodeLink, &"pos_use_xy", _pos_use_xy)


## —— ECS↔Node 桥接: 把本节点作为"数据组件"注册进 ECS ——
## 反射本节点脚本的 @export 纯数据变量(无 getter/setter)作为组件 schema,
## 注册组件并把当前变量值写入 ECS 列。之后数据由系统批量管理, 节点变量是"初始配置 + 声明"。
## 用法: 在 Entity2D 子类里声明 @export 数据字段, 设好初值后调用 register_to_ecs()。

func register_to_ecs() -> bool:
	if ecs.world == null:
		push_warning("Entity2D(%s): 未设置 world, 无法注册到 ECS。" % name)
		return false
	ecs.world.register_component(get_script())
	if not ecs.add_component(self):
		return false
	_auto_bind_position()
	return true


## 自动绑定位置字段: 若组件 schema 含 x+y(或 Vector2 pos), 记录位置字段供
## sync_ecs_to_node()/sync_node_to_ecs() 使用 —— 免手动 bind_pos/bind_pos_xy。
func _auto_bind_position() -> void:
	var schema: Dictionary = ECSNative.collect_schema(self, true)
	var has := {}
	for f in schema.get("fields", []):
		has[f.name] = true
	if has.has("x") and has.has("y"):
		bind_pos_xy(get_script(), &"x", &"y")
	elif has.has("pos"):
		bind_pos(get_script(), &"pos")


## —— 位置同步(ECS ↔ 节点) ——
## 适用于单实体/低频同步(关键实体、交互时)。海量批量请用列直读(get_column)循环赋值,
## 避免逐实体 get_field/set_field 的跨语言开销。

func bind_pos(component: Script, field: StringName = &"pos") -> void:
	_pos_comp = component
	_pos_field = field
	_pos_use_xy = false


func bind_pos_xy(component: Script, x_field: StringName = &"x", y_field: StringName = &"y") -> void:
	_pos_comp = component
	_pos_use_xy = true
	_x_field = x_field
	_y_field = y_field


## ECS → 节点
func sync_ecs_to_node() -> void:
	if _pos_comp == null:
		return
	position = _read_ecs_position()


## 节点 → ECS
func sync_node_to_ecs() -> void:
	if _pos_comp == null or ecs.entity_id < 0:
		return
	if _pos_use_xy:
		ecs.set_field(_pos_comp, _x_field, position.x)
		ecs.set_field(_pos_comp, _y_field, position.y)
	else:
		ecs.set_field(_pos_comp, _pos_field, position)


func _read_ecs_position() -> Vector2:
	if _pos_use_xy:
		return Vector2(ecs.get_field(_pos_comp, _x_field), ecs.get_field(_pos_comp, _y_field))
	var v = ecs.get_field(_pos_comp, _pos_field)
	if v is Vector2:
		return v
	if v is Vector3:
		return Vector2(v.x, v.y)
	return Vector2.ZERO
