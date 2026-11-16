extends Node3D

## 3D 弹幕 demo —— 把四个模块串成一条真实链路，直接看效果与耗时。
##
##   ① Spawner   ：按间隔批量生成一波弹丸（`instantiate` 一次建 n 个）
##   ② Projectile：整列积分位置 + 寿命到期回收
##   ③ MultiMesh ：把位置列整块写进 MultiMesh（一份网格画全部弹丸）
##   ④ PopupText ：弹丸到期处弹伤害数字（Label3D 池，不 new/queue_free）
##
## 数据流: Spawner 生成 → 每帧 Projectile 推进 → 到期发事件 → 飘字生成
##        → MultiMesh 同步位置 → PopupText 同步到节点池
##
## 操作: [1] 开/关波次   [W]/[S] 每波数量   [P] 开/关飘字   [R] 重置
## HUD : 弹丸数 / 飘字数 / 各阶段耗时 / FPS

const BULLET_SPEED := 55.0
const BULLET_LIFE := 1.4
const TARGET_RADIUS := 34.0

var _world: ECSWorld
var _mm: MultiMesh
var _mm_sys: MultiMeshSystem
var _popup_sys: PopupTextSystem
var _popup_root: Node3D
var _spawner := -1
var _prefab := -1

var _per_wave := 60
var _waves_on := true
var _popup_on := true
var _spawner_enabled := true   # 与 _waves_on 同步, 用于'只在变化时写 enabled'

var _hud: Label
var _t := 0.0
var _spawn_ms := 0.0
var _proj_ms := 0.0
var _sync_ms := 0.0
var _popup_ms := 0.0
var _bullets := 0
var _popups := 0


func _ready() -> void:
	_build_env()
	_reset()
	set_process(true)


func _build_env() -> void:
	var cam := Camera3D.new()
	cam.position = Vector3(0, 42, 96)
	cam.rotation_degrees = Vector3(-24, 0, 0)
	cam.far = 800.0
	add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	add_child(light)

	var hud_layer := CanvasLayer.new()
	add_child(hud_layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_font_size_override("font_size", 17)
	hud_layer.add_child(_hud)


func _box(size: Vector3, color: Color) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.material = mat
	return m


func _reset() -> void:
	if _popup_root != null:
		_popup_root.queue_free()
	if is_instance_valid(_mm_instance()):
		_mm_instance().queue_free()

	_world = ECSWorld.new(false)
	_world.register_component(MultiMeshComponent)
	_world.register_component(ProjectileComponent)
	_world.register_component(PopupTextComponent)
	_world.register_component(SpawnerComponent)

	# 弹丸模板: 位置/速度/寿命 + 渲染条目(同实体两个组件)
	_prefab = _world.create_prefab()
	_world.prefab_add(_prefab, ProjectileComponent, {
		&"pos": Vector3.ZERO, &"vel": Vector3.ZERO, &"life": BULLET_LIFE, &"tag": 0,
	})
	_world.prefab_add(_prefab, MultiMeshComponent, {
		&"layer": 0, &"pos": Vector3.ZERO, &"rot": Vector3.ZERO,
		&"scale": Vector3.ONE, &"color": Color(0.35, 0.8, 1.0),
	})

	# MultiMesh: 一份小方块, 用它画所有弹丸
	_mm = MultiMesh.new()
	_mm.mesh = _box(Vector3(0.9, 0.9, 2.6), Color(0.35, 0.8, 1.0))
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	mmi.name = "Bullets"
	add_child(mmi)
	_mm_sys = MultiMeshSystem.new()
	_mm_sys.bind(0, _mm)

	# 飘字池
	_popup_root = Node3D.new()
	_popup_root.name = "Popups"
	add_child(_popup_root)
	_popup_sys = PopupTextSystem.new()
	_popup_sys.bind_pool(_popup_root, 192, 96)

	# 生成器: 每 0.25s 一波, 上限 4000
	_spawner = SpawnerSystem.add(_world, _prefab, 0.25, _per_wave, 4000, 0)
	_spawner_enabled = _waves_on
	SpawnerSystem.set_enabled(_world, _spawner, _waves_on)
	_world.emit_event(&"spawner_wave", {"count": 0})   # 占位, 无实际作用

	# 波次生成 → 给每个新弹丸一个随机方向(逐条初始化, 一波才几十个)
	_world.on_event(&"spawner_wave", func(p) -> void:
		for id in (p.get("ids", PackedInt32Array()) as PackedInt32Array):
			var a := randf() * TAU
			var pitch := randf_range(-0.25, 0.25)
			var dir := Vector3(cos(a), pitch, sin(a)).normalized()
			_world.set_field(id, ProjectileComponent, &"vel", dir * BULLET_SPEED)
	)

	# 命中(到期) → 在该处弹一个伤害数字
	_world.on_event(&"projectile_expired", func(p) -> void:
		if not _popup_on:
			return
		var e := _world.create_entity()
		_world.add_component(e, PopupTextComponent, {
			&"pos": p.get("pos", Vector3.ZERO),
			&"life": 0.9, &"ttl": 0.9, &"rise": 6.0,
			&"text": "-%d" % (80 + int(randi() % 60)),
			&"color": Color(1.0, 0.55, 0.4),
		})
		_popups += 1
	)

	_t = 0.0
	_bullets = 0
	_popups = 0


func _mm_instance() -> MultiMeshInstance3D:
	for c in get_children():
		if c is MultiMeshInstance3D and c.name == "Bullets":
			return c
	return null


func _process(delta: float) -> void:
	if _world == null:
		return
	_t += delta

	# ① 生成波次(受开关控制)。只在状态变化时写 enabled: set_field 是跨语言调用, 每帧写同值没意义;
	#    而且世界被重置(R)后 _spawner 可能指向别的实体, 每帧写等于每帧赌一次。
	if _waves_on != _spawner_enabled:
		SpawnerSystem.set_enabled(_world, _spawner, _waves_on)
		_spawner_enabled = _waves_on
	var t0 := Time.get_ticks_usec()
	SpawnerSystem.tick(_world, delta)
	_spawn_ms = float(Time.get_ticks_usec() - t0) / 1000.0

	# ② 弹丸推进 + 到期回收(到期时会发事件)
	var t1 := Time.get_ticks_usec()
	ProjectileSystem.tick(_world, delta)
	_proj_ms = float(Time.get_ticks_usec() - t1) / 1000.0

	# ③ 派发本帧事件(生成的 id / 到期位置) —— 必须在同步渲染之前
	_world.tick(0.0)

	# ④ 位置列 → MultiMesh(整块 buffer)
	var t2 := Time.get_ticks_usec()
	_mm_sys.sync(_world)
	_sync_ms = float(Time.get_ticks_usec() - t2) / 1000.0

	# ⑤ 飘字: 数据侧推进 + 视图侧同步
	var t3 := Time.get_ticks_usec()
	PopupTextSystem.advance(_world, delta)
	_popup_sys.sync(_world)
	_popup_ms = float(Time.get_ticks_usec() - t3) / 1000.0

	_bullets = _world.count(ProjectileComponent)
	_update_hud()


func _update_hud() -> void:
	_hud.text = "\n".join([
		"3D 弹幕 demo —— Spawner → Projectile → MultiMesh + PopupText",
		"弹丸: %d   飘字(池上限 192): %d   FPS: %d" % [_bullets, _popup_sys.pooled_count(), Engine.get_frames_per_second()],
		"生成 %.2f ms   推进 %.2f ms   渲染同步 %.2f ms   飘字 %.2f ms" % [
			_spawn_ms, _proj_ms, _sync_ms, _popup_ms],
		"每波 %d   [1] 波次 %s   [W]/[S] 调量   [P] 飘字 %s   [R] 重置" % [
			_per_wave, "开" if _waves_on else "关", "开" if _popup_on else "关"],
	])


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_1:
			_waves_on = not _waves_on
		KEY_P:
			_popup_on = not _popup_on
		KEY_W:
			_per_wave = mini(_per_wave + 20, 400)
			if _spawner >= 0 and _world.is_alive(_spawner):
				_world.set_field(_spawner, SpawnerComponent, &"per_wave", _per_wave)
		KEY_S:
			_per_wave = maxi(_per_wave - 20, 20)
			if _spawner >= 0 and _world.is_alive(_spawner):
				_world.set_field(_spawner, SpawnerComponent, &"per_wave", _per_wave)
		KEY_R:
			_reset()
