extends Node3D

## MultiMesh 批量渲染「对照 demo」—— 同一份数据，两条显式路径，直接看差别。
##
##   模式 A（默认）: ECS 实体 + MultiMeshComponent + MultiMeshSystem
##                  → 一份网格 + 一份材质, N 个实例, 1 个渲染对象
##   模式 B:        每实体一个 MeshInstance3D
##                  → N 个节点, 每个都带自己的变换/可见性/包围盒
##
## 操作: [1] A  [2] B  [W] 加 1000  [S] 减 1000  [R] 重置
## HUD 显示: 模式 / 实例数 / 数据更新 ms / 渲染同步 ms / 绘制调用 / 渲染对象数
##
## 为什么这样比：
##   · 两种模式都**自己做同样的数据更新**(给每个元素写 y), 所以"数据更新 ms"可比；
##   · A 额外多一段"渲染同步 ms"(把列批量写进 MultiMesh, 1~2 次跨语言)；
##   · B 没有同步段, 但它的"数据更新"里包含了 N 次 set_position(触发变换通知)。
##
## 实测(本机, 10000 个, 游戏内 60+ 帧):
##   模式 A: 数据更新 1.35ms + 同步 0.57ms, 渲染对象 167,  FPS 118
##   模式 B: 数据更新 4.53ms              , 渲染对象 10174, FPS 70
##   ⚠ 绘制调用两者接近(36 vs 39) —— Godot 4 的渲染器会对相同网格/材质自动合批,
##     所以"draw call"在本引擎里不是判断依据; 真实差距在**逐节点开销 + 渲染对象数**。

const N_MIN := 1000
const N_STEP := 1000
const N_MAX := 30000

var _n := 10000
var _mode := 0            # 0 = ECS + MultiMesh, 1 = 每实体一个节点
var _world: ECSWorld
var _sys: MultiMeshSystem
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _node_root: Node3D
var _nodes: Array[MeshInstance3D] = []

var _label: Label
var _t := 0.0
var _data_ms := 0.0
var _sync_ms := 0.0


func _ready() -> void:
	_build_env()
	_rebuild()
	set_process(true)


func _build_env() -> void:
	var cam := Camera3D.new()
	cam.position = Vector3(0, 120, 210)
	cam.rotation_degrees = Vector3(-32, 0, 0)
	cam.far = 2000.0
	add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-52, -28, 0)
	add_child(light)

	var hud := CanvasLayer.new()
	add_child(hud)
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_font_size_override("font_size", 17)
	hud.add_child(_label)


func _shared_mesh() -> BoxMesh:
	var m := BoxMesh.new()
	m.size = Vector3(2, 2, 2)
	return m


func _shared_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.75, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return mat


func _spawn_pos(i: int) -> Vector3:
	var ring := float(i) / float(maxi(_n, 1))
	var a := ring * TAU * 7.0
	var r := 25.0 + 85.0 * ring
	return Vector3(cos(a) * r, 0.0, sin(a) * r)


func _clear() -> void:
	if _mmi != null and is_instance_valid(_mmi):
		_mmi.queue_free()
		_mmi = null
	if _node_root != null and is_instance_valid(_node_root):
		_node_root.queue_free()
		_node_root = null
	_nodes.clear()
	_world = null
	_sys = null
	_mm = null


func _rebuild() -> void:
	_clear()
	_t = 0.0
	if _mode == 0:
		_world = ECSWorld.new(false)
		_world.register_component(MultiMeshComponent)
		var pf := _world.create_prefab()
		_world.prefab_add(pf, MultiMeshComponent, {
			&"layer": 0,
			&"pos": Vector3.ZERO,
			&"rot": Vector3.ZERO,
			&"scale": Vector3.ONE,
			&"color": Color(0.35, 0.75, 1.0, 1.0),
		})
		_world.instantiate(pf, _n)
		var pos := PackedVector3Array()
		pos.resize(_n)
		for i in _n:
			pos[i] = _spawn_pos(i)
		_world.set_columns_of(MultiMeshComponent, {&"pos": pos})

		_mm = MultiMesh.new()
		_mm.mesh = _shared_mesh()
		_mm.transform_format = MultiMesh.TRANSFORM_3D
		_mm.use_colors = true
		_mmi = MultiMeshInstance3D.new()
		_mmi.multimesh = _mm
		_mmi.material_override = _shared_material()
		add_child(_mmi)

		_sys = MultiMeshSystem.new()
		_sys.bind(0, _mm)          # 显式绑定: 不做任何"按数量自动切换"
		_sys.sync(_world)
	else:
		_node_root = Node3D.new()
		add_child(_node_root)
		var mesh := _shared_mesh()
		var mat := _shared_material()
		for i in _n:
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = mat
			mi.position = _spawn_pos(i)
			_node_root.add_child(mi)
			_nodes.append(mi)


func _process(delta: float) -> void:
	_t += delta
	var t0 := Time.get_ticks_usec()
	if _mode == 0 and _world != null:
		# 数据更新: 取列 → 本地改 → 写回(每帧 2 次跨语言, 不是逐实体)
		var pos: PackedVector3Array = _world.get_column(MultiMeshComponent, &"pos")
		for i in pos.size():
			var v := pos[i]
			v.y = sin(_t * 2.0 + float(i) * 0.012) * 7.0
			pos[i] = v
		_world.set_columns_of(MultiMeshComponent, {&"pos": pos})
		_data_ms = float(Time.get_ticks_usec() - t0) / 1000.0
		# 渲染同步: 列 → MultiMesh buffer(原生侧一次写)
		var t1 := Time.get_ticks_usec()
		_sys.sync(_world)
		_sync_ms = float(Time.get_ticks_usec() - t1) / 1000.0
	elif _mode == 1:
		for i in _nodes.size():
			var p := _nodes[i].position
			p.y = sin(_t * 2.0 + float(i) * 0.012) * 7.0
			_nodes[i].position = p
		_data_ms = float(Time.get_ticks_usec() - t0) / 1000.0
		_sync_ms = 0.0
	_update_hud()


func _update_hud() -> void:
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objs := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var mode_name := "A · ECS + MultiMesh(批量实例)" if _mode == 0 else "B · 每实体一个 MeshInstance3D"
	_label.text = "\n".join([
		"模式: %s      [1] A   [2] B" % mode_name,
		"实例数: %d        [W] +%d   [S] -%d   [R] 重置" % [_n, N_STEP, N_STEP],
		"数据更新: %6.2f ms" % _data_ms,
		"渲染同步: %6.2f ms%s" % [_sync_ms, "" if _mode == 0 else "   (B 无此段)"],
		"绘制调用: %d      渲染对象: %d" % [draws, objs],
		"",
		"实测(10000 个): A 数据 1.35ms+同步 0.57ms / 对象 167 / 118fps",
		"                B 数据 4.53ms          / 对象 10174 / 70fps",
		"绘制调用两者接近(引擎自动合批) —— 差距在逐节点开销与渲染对象数。",
	])


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_1:
			_mode = 0
			_rebuild()
		KEY_2:
			_mode = 1
			_rebuild()
		KEY_W:
			_n = mini(_n + N_STEP, N_MAX)
			_rebuild()
		KEY_S:
			_n = maxi(_n - N_STEP, N_MIN)
			_rebuild()
		KEY_R:
			_rebuild()
