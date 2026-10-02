extends Node3D
## PCG 3D 生成运行时演示 —— 一个场景看完模块的四条能力线
##
## ============================ 这个场景证明什么 ============================
## PCG 现在只服务 3D，所以演示也只留四条线，每条对应模块的一层：
##
## ① **体素栅格**（结构层）—— 地表 / 洞穴 / 3D WFC / 噪声洞穴四种算法，
##    后台线程生成 + 进度条，并桥接成Godot 原生导航网格实测寻路。
## ② **3D 散布**（结构层）—— 泊松盘 / 抖动网格 / 均匀随机三种点集。
## ③ **生成管线**（Pipeline 层）—— 一份 [PCGDef] 里挂多个生成器，
##    每个生成器拿到[method PCGTool.derive_seed] 派生的独立随机流。
## ④ **双产物**（造型层）—— 同一份 [SdfField] 一次烘焙，左边出低多边形网格、
##    右边出体素模型。这一条是模块的核心主张：
##    **同一份生成数据既能产体素模型，也能产 lowpoly 场景。**
##
## 操作：鼠标左键拖拽旋转 / 滚轮缩放 / 换能力与资源即时重生成

enum Mode {
	VOXEL,## 3D 体素栅格（结构层）
	PLACE,## 3D 散布（结构层）
	PIPELINE,## 生成管线（Pipeline 层）
	PROP,## 场 → 网格 + 体素（造型层，双产物）
}

## 体素栅格算法资源（[Grid3DGenDef]）
@export var grid3d_defs: Array[Resource] = []
## 3D 散布资源（[PlacementDef3D]）
@export var placement3d_defs: Array[Resource] = []
## 生成管线（[PCGDef]）
@export var pipeline_def: PCGDef = null
## 双产物演示用的单体生成器脚本（[PropGen] 子类）
@export var prop_scripts: Array[String] = [
	"res://Scripts/Gen/ShopGen.gd",
	"res://Scripts/Gen/HospitalGen.gd",
	"res://Scripts/Gen/ToriiGen.gd",
	"res://Scripts/Gen/LanternGen.gd",
]

@onready var camera: Camera3D = %Camera3D
@onready var world: Node3D = %World
@onready var mode_option: OptionButton = %ModeOption
@onready var sub_option: OptionButton = %SubOption
@onready var seed_spin: SpinBox = %SeedSpin
@onready var log_box: RichTextLabel = %LogBox
@onready var progress_bar: ProgressBar = %ProgressBar
@onready var nav_region: NavigationRegion3D = %NavRegion3D

## —— 相机 ——
var _yaw := 0.7
var _pitch := 0.35
var _dist := 24.0

##双产物对照的左右间距（米）
const PROP_GAP := 14.0

## 用 `=` 而非 `:=`：presets() 返回 Dictionary，按键取值是 Variant，`:=` 推不出类型。
var _style = ToonStyleDef.presets()[&"anime_clean"]
var _palette = ToonPaletteDef.presets()[&"anime_daylight"]

var _busy := false


func _ready() -> void:
	for i in ["体素栅格", "3D 散布", "生成管线", "双产物对照"]:
		mode_option.add_item(i, i)
	mode_option.item_selected.connect(_on_mode_selected)
	sub_option.item_selected.connect(func(_i: int) -> void: _generate())
	seed_spin.value_changed.connect(func(_v: float) -> void: _generate())
	_reload_sub()


# ================================================================== 输入

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = clampf(_dist * 0.9, 6.0, 400.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = clampf(_dist * 1.1, 6.0, 400.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_dragging = mb.pressed
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.008
		_pitch = clampf(_pitch - mm.relative.y * 0.008, -1.45, 1.45)
		_update_camera()


var _dragging := false


# ================================================================== 模式切换

func _on_mode_selected(_i: int) -> void:
	# 导航只在体素栅格与管线（输出了栅格）下有意义
	nav_region.visible = mode_option.selected in [Mode.VOXEL, Mode.PIPELINE]
	_reload_sub()


func _reload_sub() -> void:
	sub_option.clear()
	match mode_option.selected:
		Mode.VOXEL:
			_fill_from(grid3d_defs)
		Mode.PLACE:
			_fill_from(placement3d_defs)
		Mode.PIPELINE:
			sub_option.add_item("Pipeline_World" if pipeline_def else "未配置管线", 0)
		Mode.PROP:
			for i in prop_scripts.size():
				sub_option.add_item(prop_scripts[i].get_file().get_basename(), i)
	_generate()


## 选项名统一取资源文件名 —— 生成器清单与可选项永远一致，不会出现"下拉里有、跑起来空"。
func _fill_from(defs: Array) -> void:
	for i in defs.size():
		var d: Resource = defs[i]
		var label := "资源%d" % i
		if d != null and not d.resource_path.is_empty():
			label = d.resource_path.get_file().get_basename()
		sub_option.add_item(label, i)


func _on_regen_pressed() -> void:
	_generate()


# ================================================================== 生成调度

func _generate() -> void:
	if _busy:
		return
	_busy = true
	_update_camera()
	match mode_option.selected:
		Mode.VOXEL:
			_gen_voxel()
		Mode.PLACE:
			_gen_place()
		Mode.PIPELINE:
			_gen_pipeline()
		Mode.PROP:
			await _gen_prop()
	_busy = false


# ================================================================== ① 体素栅格

func _gen_voxel() -> void:
	var def := _picked_grid3d()
	if def == null:
		_log("请在 grid3d_defs 里配置 [Grid3DGenDef] 资源")
		return
	var seed := int(seed_spin.value)
	progress_bar.visible = true
	progress_bar.value = 0.0
	var t := Time.get_ticks_msec()
	## 走带进度回调的异步入口：大体积 3D WFC 不卡主线程，UI 保持可响应。
	var grid: GeneratedGrid3D = await PCGTool.generate_grid_3d_async_progress(def, seed,
		func(p: float) -> void: progress_bar.value = p * 100.0)
	progress_bar.visible = false
	var ms := Time.get_ticks_msec() - t

	var pts := _exposed_voxels(grid, def, Vector3.ZERO)
	_render_voxels(pts, def.type == Grid3DGenDef.Type.CAVE_3D or def.type == Grid3DGenDef.Type.CAVE_NOISE_3D)
	_build_navigation(grid, def)
	_log("[体素栅格] %s %d×%d×%d\n实体 %d / %d 格耗时 %d ms\nseed=%d 可复现；导航网格见下方" % [
		Grid3DGenDef.Type.keys()[def.type], grid.width, grid.height, grid.depth,
		grid.count(def.solid_value), grid.cells.size(), ms, seed])


func _picked_grid3d() -> Grid3DGenDef:
	var i := sub_option.selected
	if i < 0 or i >= grid3d_defs.size():
		return null
	var d: Resource = grid3d_defs[i]
	return d as Grid3DGenDef if d is Grid3DGenDef else null


## 只取"露在空中的实体格"。全实心体素的表面积是 O(n³)，一屏就够卡死；
## 而任何体素世界的观感本来就来自外表面。
func _exposed_voxels(grid: GeneratedGrid3D, def: Grid3DGenDef, base: Vector3) -> PackedVector3Array:
	var pts := PackedVector3Array()
	var cave_mode := def.type == Grid3DGenDef.Type.CAVE_3D or def.type == Grid3DGenDef.Type.CAVE_NOISE_3D
	var e := def.empty_value
	for z in grid.depth:
		for y in grid.height:
			for x in grid.width:
				if grid.get_cell(x, y, z, e) != def.solid_value:
					continue
				if cave_mode:
					# 洞穴：实心是岩壁，看空腔才有意义 —— 这里反过来只留被包围的空腔壳层由渲染端近似
					pts.append(base + Vector3(x, y, z))
					continue
				if y == 0:
					continue
				for d in _DIR6:
					if grid.get_cell(x + d.x, y + d.y, z + d.z, e) == e:
						pts.append(base + Vector3(x, y, z))
						break
	return pts


## 桥接体素栅格 → Godot 自带 3D 导航：源几何交给引擎烘焙，实测跨图寻路。
func _build_navigation(grid: GeneratedGrid3D, def: Grid3DGenDef) -> void:
	nav_region.position = Vector3.ZERO
	nav_region.navigation_mesh = NavBridgeTool.bake_navigation_3d(
		grid, def.solid_value, Vector3.ZERO, 0.4, 0.25)
	# 烘焙与region 注册到 NavigationServer 需要时间，延迟后重取 map 再实测
	await get_tree().create_timer(0.6).timeout
	if not is_inside_tree():
		return
	var map := nav_region.get_navigation_map()
	var mesh := nav_region.navigation_mesh
	if mesh.get_vertices().size() < 3 or mesh.get_polygon_count() < 1:
		_log_tail("导航网格为空（本算法没有可走面）")
		return
	var a := NavigationServer3D.map_get_closest_point(map, Vector3(1, 1, 1))
	var b := NavigationServer3D.map_get_closest_point(map,
		Vector3(grid.width - 2, grid.height - 2, grid.depth - 2))
	var path := NavigationServer3D.map_get_path(map, a, b, true)
	_log_tail("导航网格：顶点 %d ／ 多边形 %d ／ 路径 %s" % [
		mesh.get_vertices().size(), mesh.get_polygon_count(),
		"OK(%d 点)" % path.size() if not path.is_empty() else "空"])


# ================================================================== ② 3D 散布

func _gen_place() -> void:
	var def := _picked_placement3d()
	if def == null:
		_log("请在 placement3d_defs 里配置 [PlacementDef3D] 资源")
		return
	var t := Time.get_ticks_msec()
	var pts := PCGTool.place_3d(def, PCGTool.make_rng(int(seed_spin.value)))
	var ms := Time.get_ticks_msec() - t
	_render_points(pts, def.region_size * 0.5)
	_log("[3D 散布] %s ×%d\n生成 %d 点 ／ 区域 %s ／ 耗时 %d ms\n这里只给点集；贴地与朝向由 PropLayoutTool 负责（见 PCGWorldAssemble）" % [
		PlacementDef3D.Mode.keys()[def.mode], def.count, pts.size(), str(def.region_size), ms])


func _picked_placement3d() -> PlacementDef3D:
	var i := sub_option.selected
	if i < 0 or i >= placement3d_defs.size():
		return null
	var d: Resource = placement3d_defs[i]
	return d as PlacementDef3D if d is PlacementDef3D else null


# ================================================================== ③ 生成管线

func _gen_pipeline() -> void:
	if pipeline_def == null:
		_log("未配置 pipeline_def")
		return
	var t := Time.get_ticks_msec()
	var out := PCGTool.generate(pipeline_def, int(seed_spin.value))
	var ms := Time.get_ticks_msec() - t

	var lines: Array[String] = ["[生成管线] %d 个生成器 ／ 耗时 %d ms" % [pipeline_def.generators.size(), ms]]
	var n_grid := 0
	var n_pts := 0
	# 先把体素栅格画出来，再用散点补上—— 管线输出的顺序就是生成器顺序
	for key in out:
		var v = out[key]
		if v is GeneratedGrid3D:
			var grid: GeneratedGrid3D = v
			## 找不回原生成器就退化成"按栅格尺寸现配一个"，只用于取 solid/empty 取值
			var def := _find_grid3d(key)
			if def == null:
				def = Grid3DGenDef.new()
				def.width = grid.width
				def.height = grid.height
				def.depth = grid.depth
			_render_voxels(_exposed_voxels(grid, def, Vector3.ZERO), false)
			n_grid += 1
			lines.append("　%s → 栅格 %d×%d×%d，实体 %d 格" % [
				key, grid.width, grid.height, grid.depth, grid.count(def.solid_value)])
		elif v is PackedVector3Array:
			var pts: PackedVector3Array = v
			_render_points(pts, Vector3(0, grid_height_hint(out), 0))
			n_pts += 1
			lines.append("　%s → %d 点" % [key, pts.size()])
		else:
			lines.append("　%s → %s（本演示未渲染）" % [key, type_string(typeof(v))])
	_log("\n".join(lines))
	_log_tail("管线 %d 个栅格 / %d 个点集；每个生成器的随机流由 derive_seed 独立派生" % [n_grid, n_pts])


## 散点渲染需要知道栅格世界的高度，否则点会飘在天上。
func grid_height_hint(out: Dictionary) -> float:
	for key in out:
		var v = out[key]
		if v is GeneratedGrid3D:
			return float((v as GeneratedGrid3D).height)
	return 0.0


## 按 output_key 找管线里的 3D 栅格生成器
func _find_grid3d(key: String) -> Grid3DGenDef:
	for g in pipeline_def.generators:
		if g is Grid3DGenDef and g._effective_key() == key:
			return g
	return null


# ================================================================== ④ 双产物对照

## 一次烘焙、两种投影：同一个 [PropBuild] 的左半边挂低多边形网格、
## 右半边挂体素网格。同 seed、同一次场，必然同形。
func _gen_prop() -> void:
	var i := sub_option.selected
	if i < 0 or i >= prop_scripts.size():
		_log("未配置 prop_scripts")
		return
	var path: String = prop_scripts[i]
	var sc: Script = load(path)
	if sc == null:
		_log("脚本加载失败：%s" % path)
		return

	var def := PropGenDef.new()
	def.voxel_size = 0.18
	def.margin = 0.4
	def.algo = MeshExtractor.Algo.DUAL_CONTOURING
	def.sharp_normal = true
	## 双产物开关：体素产物与网格产物**共用同一次场烘焙**
	def.voxel_res = 40
	def.voxel_palette = _palette

	_clear_world()
	var t := Time.get_ticks_msec()
	var b = PropGenTool.bake(sc.new(), def, int(seed_spin.value))
	var ms := Time.get_ticks_msec() - t
	if b == null or b.is_empty():
		_log("[双产物] %s 烘焙出空网格" % path.get_file().get_basename())
		return

	var mesh_node := ModelBaker.build_node(b, {"style": _style, "palette": _palette, "name": "mesh"})
	mesh_node.position = Vector3(0.0, -b.bounds.position.y, 0.0)
	world.add_child(mesh_node)

	var vox_txt := "未产出（形状过于扁长，voxel_res 按最长边定尺后短边只剩一两格）"
	if b.has_voxel():
		var vox_node := ModelBaker.build_voxel_node(b.voxel, {
			"style": _style, "palette": _palette, "greedy": true, "name": "voxel"})
		vox_node.position = Vector3(PROP_GAP, -b.voxel.origin.y, 0.0)
		world.add_child(vox_node)
		vox_txt = "%d 个实体体素（%d³ 网格，边长 %.3f 米）" % [
			b.voxel.count_solid(), b.voxel.size.x, b.voxel.voxel]

	_dist = maxf(b.bounds.size.length() * 2.6, 12.0)
	_yaw = 0.9
	_pitch = 0.35
	_update_camera()
	_log("[双产物] %s ｜ 场体素 %.2f 米 ｜ 烘焙 %d ms\n左：低多边形网格 %d 三角面\n右：体素 %s\n\n场只烘了一次 —— 两种投影各自只是取面/体素化，所以双产物几乎不加钱" % [
		path.get_file().get_basename(), def.voxel_size, ms, b.triangle_count(), vox_txt])


# ================================================================== 渲染

func _clear_world() -> void:
	for child in world.get_children():
		child.queue_free()


func _render_voxels(pts: PackedVector3Array, transparent: bool) -> void:
	_clear_world()
	if pts.is_empty():
		return
	world.add_child(_multimesh(pts, BoxMesh.new(), _voxel_material(transparent)))


## 洞穴模式下实心格是岩壁、半透明才看得见里面的空腔。
func _voxel_material(transparent: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.95
	if transparent:
		mat.albedo_color = Color(0.34, 0.30, 0.28, 0.35)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	else:
		mat.albedo_color = Color(0.60, 0.65, 0.72)
	return mat


func _render_points(pts: PackedVector3Array, center: Vector3) -> void:
	_clear_world()
	if pts.is_empty():
		return
	var mesh := SphereMesh.new()
	mesh.radius = 0.4
	mesh.height = 0.8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.72, 0.30)
	mesh.material = mat
	var off := PackedVector3Array()
	for p in pts:
		off.append(p - center)
	world.add_child(_multimesh(off, mesh, mat))


func _multimesh(pts: PackedVector3Array, mesh: Mesh, mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mesh.material = mat
	mm.mesh = mesh
	mm.instance_count = pts.size()
	for i in pts.size():
		mm.set_instance_transform(i, Transform3D(Basis(), pts[i]))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	return mmi


# ================================================================== 相机 / 日志

func _update_camera() -> void:
	camera.position = Vector3(
		sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * _dist
	camera.look_at(Vector3.ZERO, Vector3.UP)


func _log(msg: String) -> void:
	if log_box != null:
		log_box.text = msg


func _log_tail(tail: String) -> void:
	if log_box != null:
		log_box.text += "\n" + tail


const _DIR6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


## 供自动化冒烟：跑一遍当前模式，确认世界里有东西生成出来。
func smoke_test() -> bool:
	await _generate()
	return not world.get_children().is_empty()