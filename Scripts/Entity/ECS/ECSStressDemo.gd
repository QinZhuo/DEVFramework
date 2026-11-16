extends Node2D

## ECS 压力对比 demo —— 同一份"移动 + 生死"循环, 分别用 ECS 与普通 Node 跑, 把差异量化。
##
## 为什么这么设计:
## 1) **不画任何东西**: 比较的是"逻辑吞吐"(遍历/写入/结构变更), 渲染差异会把结论搅浑;
## 2) **两种模式同 N、同循环**: ECS 用 columns_of + set_columns_of(框架推荐的逐帧写法),
##    Node 用 Array[Node2D] + position 赋值(最朴素的写法);
## 3) **每帧 churn**: 每秒销毁并重建若干实体/节点 —— 这才是 archetype + prefab 的主场,
##    而"建好一次只改值"的 demo 看不出差别。
##
## 操作: 1=ECS  2=Node  C=开关 churn  R=重建  Esc=退出
##
## 注意: Node 模式 N 上去会非常慢(每个 Node 都有场景树/通知开销), 这是事实而非 bug。

const Unit := preload("res://Scripts/Entity/ECS/ECSDemoMoveComponent.gd")

@export var entity_count := 20000
@export var churn_per_frame := 200
@export var start_mode := "ecs"

var _mode := "ecs"
var _world: ECSWorld = null
var _prefab := -1
var _nodes: Array[Node2D] = []
var _vels := PackedVector2Array()
var _churn := true
var _logic_us := 0.0
var _spawn_ms := 0.0
var _hud: Label


func _ready() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_font_size_override("font_size", 16)
	layer.add_child(_hud)
	randomize()
	_reset(start_mode)


func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_1:
			_reset("ecs")
		KEY_2:
			_reset("node")
		KEY_C:
			_churn = not _churn
		KEY_R:
			_reset(_mode)
		KEY_ESCAPE:
			get_tree().quit()


func _reset(mode: String) -> void:
	_clear()
	_mode = mode
	if mode == "ecs":
		_build_ecs()
	else:
		_build_nodes()
	_hud.text = "构建中…"


func _clear() -> void:
	_world = null
	_prefab = -1
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	_vels.clear()


# ---------------- ECS ----------------

func _build_ecs() -> void:
	var t0 := Time.get_ticks_usec()
	var w := ECSWorld.new(false)
	w.register_component(Unit)
	_prefab = w.create_prefab()
	w.prefab_add(_prefab, Unit, {})
	w.instantiate(_prefab, entity_count)
	# 一次性随机化初始位置/速度: 取两列 → 改 → 写回(各 1 次跨语言)
	var c := w.columns_of(Unit, [&"pos", &"vel"])
	var pos: PackedVector2Array = c[&"pos"]
	var vel: PackedVector2Array = c[&"vel"]
	for i in pos.size():
		pos[i] = Vector2(randf() * 800.0, randf() * 600.0)
		vel[i] = Vector2(randf_range(-40.0, 40.0), randf_range(-40.0, 40.0))
	w.set_columns_of(Unit, {&"pos": pos, &"vel": vel})
	_world = w
	_spawn_ms = float(Time.get_ticks_usec() - t0) / 1000.0


func _step_ecs(dt: float) -> void:
	# 逐帧推荐写法: 一次取列 → 循环 → 一次写回(而不是逐实体 get_field/set_field)
	var c := _world.columns_of(Unit, [&"pos", &"vel"])
	var pos: PackedVector2Array = c[&"pos"]
	var vel: PackedVector2Array = c[&"vel"]
	var n := pos.size()
	for i in n:
		pos[i] += vel[i] * dt
	_world.set_columns_of(Unit, {&"pos": pos})
	if not _churn:
		return
	var k := mini(churn_per_frame, n)
	if k > 0:
		var ents := _world.query_entities(Unit)
		for i in k:
			_world.destroy_entity(ents[ents.size() - 1 - i])
		_world.instantiate(_prefab, k)


# ---------------- Node 基线 ----------------

func _build_nodes() -> void:
	var t0 := Time.get_ticks_usec()
	_nodes.resize(entity_count)
	_vels.resize(entity_count)
	for i in entity_count:
		var n := Node2D.new()
		add_child(n)
		n.position = Vector2(randf() * 800.0, randf() * 600.0)
		_nodes[i] = n
		_vels[i] = Vector2(randf_range(-40.0, 40.0), randf_range(-40.0, 40.0))
	_spawn_ms = float(Time.get_ticks_usec() - t0) / 1000.0


func _step_nodes(dt: float) -> void:
	var n := _nodes.size()
	for i in n:
		var node := _nodes[i]
		if not is_instance_valid(node):
			continue
		node.position += _vels[i] * dt
	if not _churn:
		return
	var k := mini(churn_per_frame, n)
	for i in k:
		var idx := _nodes.size() - 1
		if idx < 0:
			break
		var old := _nodes[idx]
		_nodes.remove_at(idx)
		_vels.remove_at(idx)
		if is_instance_valid(old):
			old.queue_free()
		var nn := Node2D.new()
		add_child(nn)
		nn.position = Vector2(randf() * 800.0, randf() * 600.0)
		_nodes.append(nn)
		_vels.append(Vector2(randf_range(-40.0, 40.0), randf_range(-40.0, 40.0)))


# ---------------- HUD ----------------

func _process(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	if _mode == "ecs":
		if _world != null:
			_step_ecs(dt)
	else:
		_step_nodes(dt)
	var us := float(Time.get_ticks_usec() - t0)
	_logic_us = us if _logic_us <= 0.0 else lerpf(_logic_us, us, 0.12)

	var alive := 0
	if _mode == "ecs":
		alive = 0 if _world == null else _world.count(Unit)
	else:
		alive = _nodes.size()
	var objs := Performance.get_monitor(Performance.OBJECT_COUNT)
	var frame_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_hud.text = "\n".join(PackedStringArray([
		"模式: %s   (1=ECS  2=Node  C=churn  R=重建)" % ("ECS" if _mode == "ecs" else "Node 基线"),
		"实体/节点: %d   churn/帧: %s" % [alive, ("%d" % churn_per_frame) if _churn else "关"],
		"逻辑耗时: %.3f ms/帧   (上次构建 %.1f ms)" % [_logic_us / 1000.0, _spawn_ms],
		"进程帧时: %.2f ms   FPS: %d" % [frame_ms, Engine.get_frames_per_second()],
		"活对象数: %d" % objs,
	]))
