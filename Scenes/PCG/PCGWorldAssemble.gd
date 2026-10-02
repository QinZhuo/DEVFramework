extends Node3D

## SDF 世界组装演示 · 「各物体独立生成，最终只做摆放」
##
## ============================ 这个场景证明什么 ============================
## 1. **独立生成** —— 点场景里任意一个单体，只换它自己的 seed 重生成：
##    形状立刻变了，而它站在哪、朝哪**一点没动**。
##    如果生成与布局是耦合的（传统「世界生成器」写法），这一下必然连带影响世界。
##
## 2. **只做摆放** —— 组装器不含任何几何语义，它拿到的只是一句
##    「我占地 6×4.8，正面朝 +Z，贴地」。改 seed 只改前者，不改后者。
##
## 3. **存档只有 6 个字段** —— 按 S 存档（tag/seed/x/y/z/yaw），没有任何网格；
##    按 L 读档，用同一套生成器重烘 + 套回 transform，世界完整还原。
##
## 4. **烘焙贵、摆放便宜** —— 日志里的两组耗时对比：首次烘焙是秒级，
##    而缓存命中后重新组装是毫秒级。这正是「存档不存网格」换来的东西。
##
## 操作：左键拖拽旋转 / 滚轮缩放 / 左键单击单体=换形状 / R=换地图种子 / S=存档 / L=读档

@onready var camera: Camera3D = %Camera3D
@onready var world: Node3D = %World
@onready var title: Label = %Title
@onready var log_box: Label = %Log
@onready var hint: Label = %Hint
@onready var btn_regen: Button = %Regen
@onready var btn_save: Button = %Save
@onready var btn_load: Button = %Load

## —— 相机 ——
var _yaw := 0.85
var _pitch := 0.52
var _zoom := 1.0
var _look_at := Vector3(34.0, 0.0, -14.0)

var _dragging := false
var _press_pos := Vector2.ZERO

## —— 世界 ——
var _asm: WorldAssembler = null
var _placements: Array = []
var _world_seed := 20261002
var _save_rows: Array = []
var _busy := false

## 地形高度。注意：布局层**只认** `func(x, z) -> float` 这个形状，
## 它不知道也不关心这里是个 sin/cos、还是 PCG 的 HeightMap、还是别的模块。
## 换任何地形实现，这行都不用改。
static func terrain_h(x: float, z: float) -> float:
	return sin(x * 0.05) * 2.0 + cos(z * 0.08) * 1.5


func _ready() -> void:
	_build_terrain()
	_apply_sky()
	_update_camera()
	## 按钮与函数一一对应直接绑定（不在 .tscn 里连，避免漏引/改名后静默失效）
	if btn_regen != null:
		btn_regen.pressed.connect(_on_regen)
	if btn_save != null:
		btn_save.pressed.connect(_do_save)
	if btn_load != null:
		btn_load.pressed.connect(_do_load)
	_assemble_world()


func _on_regen() -> void:
	_world_seed += 1
	_assemble_world()


## ============================ 组装 ============================

func _make_assembler() -> WorldAssembler:
	var a := WorldAssembler.new()
	a.ground_y = Callable(self, "terrain_h")
	a.street_step = 4.0
	## voxel 取值是演示级的粗精度：只为快速呈现。
	## 生产精度与耗时量级见 addons/DEVFramework/PCG/Readme.md §5。
	a.add_recipe(_recipe("street", "res://Scripts/Gen/StreetGen.gd", 3, 0, 0.40))
	a.add_recipe(_recipe("shop", "res://Scripts/Gen/ShopGen.gd", 6, 1, 0.30))
	a.add_recipe(_recipe("vehicle", "res://Scripts/Gen/VehicleGen.gd", 4, 2, 0.20))
	a.add_recipe(_recipe("hospital", "res://Scripts/Gen/HospitalGen.gd", 1, 3, 0.40))
	return a


func _recipe(tag: String, script: String, count: int, place: int, voxel: float) -> PropRecipe:
	var r := PropRecipe.new()
	r.tag = tag
	r.gen_script = load(script)
	r.count = count
	r.place = place
	r.voxel_size = voxel
	r.kind_id = tag.hash() % 97
	return r


func _assemble_world() -> void:
	if _busy:
		return
	_busy = true
	_clear_world()
	## 同一个组装器实例复用 —— 它的 build 缓存跨调用有效，
	## 所以切回旧 seed 时是毫秒级返回，而不是重新烘一遍。
	if _asm == null:
		_asm = _make_assembler()

	## ★ 分帧烘焙：每帧只做一个单体，主循环不被堵死。
	##   界面全程可响应，进度也在实时更新 —— 这正是 [method WorldAssembler.assemble_step]
	##   存在的理由。烘焙耗时单独累加，不把 await 的帧间隔算进去。
	var bake_ms := 0
	var frames := 0
	while true:
		var s0 := Time.get_ticks_msec()
		var done := _asm.assemble_step(_world_seed)
		bake_ms += Time.get_ticks_msec() - s0
		if done:
			break
		frames += 1
		_log("烘焙中 %d%% ｜ 剩余 %d 个单体 ｜ 已用 %d ms" % [
			int(_asm.step_progress() * 100.0), _asm.step_pending(), bake_ms])
		await get_tree().process_frame

	var t1 := Time.get_ticks_msec()
	_placements = _asm.assemble_finish(_world_seed)
	var lay_ms := Time.get_ticks_msec() - t1

	_render(_placements)
	_busy = false

	var tri := 0
	for p in _placements:
		var pl: PropLayoutTool.Placement = p
		if pl.build != null:
			tri += pl.build.triangle_count()

	title.text = "SDF 世界组装 · 地图种子 %d" % _world_seed
	_log("地图种子 %d ｜ %d 个单体 ｜ %d 三角面 ｜ **烘焙 %d ms**（分 %d 帧，主循环未阻塞）｜ 布局 %d ms%s" % [
		_world_seed, _placements.size(), tri, bake_ms, frames, lay_ms,
		("｜全部命中缓存" if bake_ms < 400 else "")])
	_log2("左键拖拽旋转 · 滚轮缩放 · **单击任意单体 = 只换它的形状，位置不动** · R 换地图种子 · S 存档 · L 读档")


func _clear_world() -> void:
	## 只清单体，**保留地形** —— 否则重新烘焙的那十几秒里画面是空的
	for c in world.get_children():
		if c.name != "Terrain":
			c.queue_free()


## ============================ 渲染 ============================

func _render(placements: Array) -> void:
	for p in placements:
		var pl: PropLayoutTool.Placement = p
		var tag := String(pl.meta.get(&"tag", "prop"))
		var mi := pl.instantiate(_material_of(tag))
		if mi == null:
			continue
		## 起个可读名字：调试时在场景树里一眼能认出是哪种单体
		mi.name = "%s_%d" % [tag, pl.seed_value]
		world.add_child(mi)
		## 挂一个盒碰撞体只为「点选」，并把 seed 挂在它身上 ——
		## 形状由 seed 唯一决定，点中就知道该重烘哪个。
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = pl.build.bounds.size
		cs.shape = box
		cs.position = pl.build.bounds.get_center()
		body.add_child(cs)
		body.set_meta(&"seed_value", pl.seed_value)
		body.set_meta(&"tag", tag)
		mi.add_child(body)


func _material_of(tag: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.roughness = 0.85
	match tag:
		"street":
			m.albedo_color = Color(0.28, 0.29, 0.32)
		"shop":
			m.albedo_color = Color(0.86, 0.47, 0.32)
		"vehicle":
			m.albedo_color = Color(0.30, 0.52, 0.85)
		"hospital":
			m.albedo_color = Color(0.90, 0.91, 0.93)
		_:
			m.albedo_color = Color(0.7, 0.7, 0.7)
	return m


## 起伏地形。布局层拿到的是 terrain_h 这个函数，
## 它照样能把每个单体贴到这张起伏地面上 —— 两者互不知情。
func _build_terrain() -> void:
	var step := 1.5
	var x0 := -24.0
	var x1 := 112.0
	var z0 := -92.0
	var z1 := 40.0
	var nx := int((x1 - x0) / step)
	var nz := int((z1 - z0) / step)

	## 先算出全部顶点，再按「每 3 个顶点一个三角形」提交 ——
	## SurfaceTool 没有 add_triangle(索引) 这类 API，它只认 add_vertex。
	var verts := PackedVector3Array()
	verts.resize((nx + 1) * (nz + 1))
	for iz in nz + 1:
		for ix in nx + 1:
			var x := x0 + float(ix) * step
			var z := z0 + float(iz) * step
			verts[iz * (nx + 1) + ix] = Vector3(x, terrain_h(x, z), z)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in nz:
		for ix in nx:
			var a := iz * (nx + 1) + ix
			var b := a + 1
			var c := a + (nx + 1)
			var d := c + 1
			## 法线显式给 +Y：地形是高度场，法线必然朝上，
			## 不依赖 generate_normals() 对绕序的假设（绕序反了法线就会朝下）。
			st.set_normal(Vector3.UP)
			st.add_vertex(verts[a]); st.add_vertex(verts[c]); st.add_vertex(verts[b])
			st.add_vertex(verts[b]); st.add_vertex(verts[c]); st.add_vertex(verts[d])

	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.36, 0.52, 0.33)
	m.roughness = 1.0
	## 同理不依赖绕序约定：单面地形直接双面可见，避免"整块看不见"这种难查问题
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	world.add_child(mi)


func _apply_sky() -> void:
	var env := get_node_or_null("Env") as WorldEnvironment
	if env != null and env.environment != null:
		var e := env.environment
		e.background_mode = Environment.BG_SKY
		var sky := Sky.new()
		var sky_mat := ProceduralSkyMaterial.new()
		sky_mat.sky_top_color = Color(0.30, 0.48, 0.78)
		sky_mat.sky_horizon_color = Color(0.72, 0.80, 0.88)
		sky_mat.ground_bottom_color = Color(0.32, 0.30, 0.26)
		sky.sky_material = sky_mat
		e.sky = sky
		e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		e.ambient_light_energy = 1.0


## ============================ 交互 ============================

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom = clampf(_zoom * 0.9, 0.25, 3.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom = clampf(_zoom * 1.1, 0.25, 3.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_press_pos = mb.position
			else:
				_dragging = false
				## 按下与抬起几乎同点 = 点击（而非拖拽）
				if mb.position.distance_to(_press_pos) < 6.0:
					_pick_at(mb.position)
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.006
		_pitch = clampf(_pitch - mm.relative.y * 0.006, -1.45, 1.45)
		_update_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_R:
				_world_seed += 1
				_assemble_world()
			KEY_S:
				_do_save()
			KEY_L:
				_do_load()


func _update_camera() -> void:
	var dist := 92.0 * _zoom
	camera.position = _look_at + Vector3(
		sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * dist
	camera.look_at(_look_at, Vector3.UP)


## 点选单体 → **只**重烘它自己的 seed，transform 分毫不动。
## 这是「独立生成 + 只做摆放」最直接的现场证据。
func _pick_at(screen_pos: Vector2) -> void:
	if _busy:
		return
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 500.0
	var q := get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(from, to))
	if q.is_empty():
		return
	var body: Node = q.get("collider")
	if body == null or not body.has_meta(&"seed_value"):
		return

	var tag: String = body.get_meta(&"tag", "")
	var old_seed: int = body.get_meta(&"seed_value", 0)
	var mi := body.get_parent() as MeshInstance3D

	## 换一个与旧 seed 无关的新 seed
	var new_seed := (old_seed * 1103515245 + 12345) & 0x7FFFFFFF
	var r := _find_recipe(tag)
	if r == null or mi == null:
		return

	## ★ 整个过程只用到「配方 + 新 seed」。没有世界、没有其它单体、没有布局表。
	##   布局层压根没被调用 —— 因为位置压根不需要重算。
	var t0 := Time.get_ticks_msec()
	var b := PropGenTool.bake(r.gen_script.new(), r.make_gen_def(), new_seed)
	var ms := Time.get_ticks_msec() - t0
	if b == null or b.is_empty():
		_log("烘焙失败：%s" % tag)
		return

	var keep_xform := mi.transform
	## SdfMesh 不是 Mesh（它只是提取出来的顶点/索引缓冲），落地要转成 ArrayMesh
	mi.mesh = b.mesh.to_arraymesh(_material_of(tag))
	mi.transform = keep_xform      ## ← 原封不动。这是本演示要说明的全部。
	var new_body := body
	new_body.set_meta(&"seed_value", new_seed)
	var cs := new_body.get_child(0) as CollisionShape3D
	if cs != null:
		var box := cs.shape as BoxShape3D
		if box != null:
			box.size = b.bounds.size
		cs.position = b.bounds.get_center()

	_log("重生成 %s：seed %d → %d ｜ %d 三角面 ｜ 耗时 %d ms ｜ **位置与朝向未变**" % [
		tag, old_seed, new_seed, b.triangle_count(), ms])


func _find_recipe(tag: String) -> PropRecipe:
	if _asm == null:
		return null
	for r in _asm.recipes:
		if r != null and r.tag == tag:
			return r
	return null


## ============================ 存档 / 读档 ============================

## 存档：6 个字段一条，**没有网格**。
func _do_save() -> void:
	_save_rows = WorldAssembler.save_data(_placements)
	var sample: Dictionary = _save_rows[0] if _save_rows.size() > 0 else {}
	var fields := PackedStringArray()
	for k in sample.keys():
		fields.append("%s=%s" % [k, str(sample[k]).substr(0, 18)])
	_log("存档 %d 条，每条 %d 字段，**零网格**：%s" % [
		_save_rows.size(), sample.size(), ", ".join(fields)])
	_log2("读档(L)会用同一套生成器按 seed 重烘，再把 x/y/z/yaw 套回去 —— 无需存档任何顶点。")


## 读档：证明「6 个字段足以完整还原一个世界」。
## 位置不重新计算（那会引入布局层的随机性），而是直接套存档里的 transform。
func _do_load() -> void:
	if _save_rows.is_empty():
		_log("没有存档，先按 S")
		return
	if _busy:
		return
	_busy = true
	_clear_world()

	var bake_ms := 0
	var restored: Array = []
	var n := _save_rows.size()
	for idx in n:
		var row: Dictionary = _save_rows[idx]
		var r := _find_recipe(String(row[&"tag"]))
		if r == null:
			continue
		var s0 := Time.get_ticks_msec()
		var b := PropGenTool.bake(r.gen_script.new(), r.make_gen_def(), int(row[&"seed"]))
		bake_ms += Time.get_ticks_msec() - s0
		if b != null and not b.is_empty():
			## 只借用布局器做一次「无地面」的落位，随后 transform 被存档值整体覆盖
			var pl := PropLayoutTool.solve(b, int(row[&"seed"]),
				Vector2(float(row[&"x"]), float(row[&"z"])), float(row[&"yaw"]),
				Callable(), {&"snap": PropLayoutTool.Snap.NONE})
			if pl != null:
				## yaw 字段与 xform 必须一起改：只改 xform 的话 Placement.yaw
				## 仍是 solve() 的初值（Snap.NONE 下通常是 0），
				## 对象状态与实际朝向不一致，二次存档就会写出错的 yaw。
				pl.yaw = float(row[&"yaw"])
				pl.xform = Transform3D(Basis(Vector3.UP, pl.yaw),
					Vector3(float(row[&"x"]), float(row[&"y"]), float(row[&"z"])))
				restored.append(pl)
		## 同样分帧：读档要重烘全部单体，一次性做完会冻结界面
		_log("读档中 %d/%d ｜ seed %d 已重烘 ｜ 累计 %d ms" % [idx + 1, n, int(row[&"seed"]), bake_ms])
		await get_tree().process_frame

	_placements = restored
	_render(restored)
	_busy = false
	_log("读档还原 %d/%d 条 ｜ 重烘耗时 %d ms ｜ 网格全部由 seed 重建，transform 直接取自存档" % [
		restored.size(), n, bake_ms])
	_log2("同一批 seed 必然烘出同一批网格 —— 这就是「不存网格也能还原」的依据。")


## ============================ 输出 ============================

func _log(msg: String) -> void:
	if log_box != null:
		log_box.text = msg


func _log2(msg: String) -> void:
	if hint != null:
		hint.text = msg


## 供 TestRunner / 自动化冒烟：跑一次完整组装，确认链路可用。
func smoke_test() -> bool:
	_assemble_world()
	return _placements.size() >= 12 and not PropLayoutTool.has_overlap(_placements, 0.95)
