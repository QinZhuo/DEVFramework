extends Node3D

## 模型陈列馆 —— **"一份数据两种用途"的可视化测试场**
##
## ============================ 这个场景验的是什么 ============================
## 风格包演示（StyleSceneDemo）验的是"整场景换画风"，但它把网格与体素分开两次烘焙才能看到，
## 看不出二者是否真的同源。这里相反：**每个生成器只烘焙一次**，同一个 [PropBuild] 的
## 左半边挂低多边形网格、右半边挂体素网格，同 seed、同一次场、必然同形。
##
## 把 8 个生成器并排列出来，还顺手暴露两件容易漏掉的事：
## · 扁长物体（街道 24 × 0.6 × 10.8）体素化后会退化 —— [constant SdfVoxel] 侧留空
## · 各生成器的包围盒尺寸差异极大，摆位必须按实际 bounds 累进而非固定间距
##
## 左半区 = 低多边形网格（[method ModelBaker.build_node]，含三渲二材质与倒壳描边）
## 右半区 = 体素网格（[method ModelBaker.build_voxel_node]，贪心合并）
##
## 操作：左键拖拽旋转 / 滚轮缩放 / R 换种子

## 生成器清单。新增生成器时往这里加一行即可 —— 展馆是"生成器目录"的活体文档。
const GENS := [
	["shop", "res://Scripts/Gen/ShopGen.gd"],
	["hospital", "res://Scripts/Gen/HospitalGen.gd"],
	["street", "res://Scripts/Gen/StreetGen.gd"],
	["vehicle", "res://Scripts/Gen/VehicleGen.gd"],
	["torii", "res://Scripts/Gen/ToriiGen.gd"],
	["lantern", "res://Scripts/Gen/LanternGen.gd"],
	["shrinehall", "res://Scripts/Gen/ShrineHallGen.gd"],
	["candyhouse", "res://Scripts/Gen/CandyHouseGen.gd"],
]

## 统一的烘焙参数。刻意不用风格包那套 —— 展馆要横向可比，
## 同一份参数下每个生成器才能看出"造型差异"而不是"参数差异"。
##
## 0.16 是精度优先的取值，但陈列馆要一口气烘 8 个：实测 HospitalGen 单个 14.5 秒，
## 八件套接近一分钟，翻个种子就得等。展馆是"看造型"的地方，不是出最终资产，
## 所以取 0.20 / 32 —— 面数与体素数各降一档，造型特征一概不少。
const VOXEL_SIZE := 0.20
const VOXEL_RES := 32

## 两列的横向间距（米）。体素列比网格列远，因为体素块看着更"胖"。
const COL_GAP := 16.0
## 行间距的额外留白（米）
const ROW_PAD := 5.0

@onready var world: Node3D = %World
@onready var camera: Camera3D = %Camera3D
@onready var title: Label = %Title
@onready var table: RichTextLabel = %Table
@onready var hint: Label = %Hint

## 用 `=` 而非 `:=`：presets() 返回 Dictionary，按键取值是 Variant，
## `:=` 在这里推不出类型，编译期就会失败。
var _style = ToonStyleDef.presets()[&"anime_clean"]
var _palette = ToonPaletteDef.presets()[&"anime_daylight"]

var _yaw := 0.9
var _pitch := 0.45
var _zoom := 1.0
var _center := Vector3(4.0, 2.0, 0.0)
var _dragging := false
var _seed := 20261002
var _busy := false
## 排布总长（米）。相机距离由它决定 —— 各生成器尺寸差异极大，
## 固定距离必然要么看不全、要么缩成芝麻，取景只能跟着实际排布走。
var _span := 60.0


func _ready() -> void:
	_apply_sky()
	await _rebuild()


# ================================================================== 烘焙

func _gen_def() -> PropGenDef:
	var d := PropGenDef.new()
	d.voxel_size = VOXEL_SIZE
	d.margin = 0.4
	d.algo = MeshExtractor.Algo.DUAL_CONTOURING
	d.sharp_normal = true
	## 双产物：一次烘焙同时给出网格与体素，这正是本场景要证明的事
	d.voxel_res = VOXEL_RES
	d.voxel_palette = _palette
	return d


func _rebuild() -> void:
	if _busy:
		return
	_busy = true
	for c in world.get_children():
		c.queue_free()

	var gd := _gen_def()
	var rows: Array[String] = []
	rows.append("%-12s %8s %9s   %s" % ["生成器", "面数", "体素数", "包围盒(米)"])
	var z := 0.0
	var span := 0.0
	var total_ms := 0
	var n_voxel := 0

	for item in GENS:
		var tag: String = item[0]
		var path: String = item[1]
		var sc := load(path)
		if sc == null:
			rows.append("%-12s 脚本加载失败" % tag)
			continue
		var t0 := Time.get_ticks_msec()
		var b = PropGenTool.bake(sc.new(), gd, _seed)
		total_ms += Time.get_ticks_msec() - t0
		if b == null or b.is_empty():
			rows.append("%-12s 烘焙出空网格" % tag)
			## 仍然推进 z，否则后面的行会全部叠在这一行的位置
			z += 6.0 + ROW_PAD
			continue

		var mn := ModelBaker.build_node(b, {
			"style": _style, "palette": _palette, "name": "%s_mesh" % tag})
		mn.position = Vector3(0.0, 0.0, z)
		world.add_child(mn)

		var vz := 0.0
		var vox_ok := "—"
		if b.has_voxel():
			var vn := ModelBaker.build_voxel_node(b.voxel, {
				"style": _style, "palette": _palette, "greedy": true,
				"name": "%s_vox" % tag})
			vn.position = Vector3(COL_GAP, 0.0, z)
			world.add_child(vn)
			var solid = b.voxel.count_solid()
			vz = float(b.voxel.size.z) * b.voxel.voxel
			vox_ok = "%d (%d³)" % [solid, b.voxel.size.x]
			n_voxel += 1
		else:
			## 这里刻意**不**补一个网格占位。留空本身就是有效信息：
			## 体素化对扁长物体会退化，展馆要让人一眼看出"哪个撑不住体素"。
			vox_ok = "未产出（形状过于扁长）"

		rows.append("%-12s %8d %s   %s" % [
			tag, b.triangle_count(), vox_ok, str(b.bounds.size)])
		z += maxf(maxf(b.bounds.size.z, vz), 4.0) + ROW_PAD
		_span = z
		_log("\n正在烘焙 %s …（累计 %d ms）" % [tag, total_ms])
		await get_tree().process_frame

	## —— 取景：按实际排布长度自动拉远，别让末尾几个跑出画面 ——
	_center = Vector3(COL_GAP * 0.5, 2.0, _span * 0.5)
	_zoom = clampf(_span / 60.0, 0.6, 4.0)
	_update_camera()

	title.text = "模型陈列馆 ｜ 种子 %d ｜ 一次烘焙，网格与体素同源对照" % _seed
	table.text = "\n".join(rows)
	_log("%d 个生成器 ｜ %d 个产出体素 ｜ 烘焙共 %d ms ｜ 统一参数 voxel=%.2f res=%d" % [
		GENS.size(), n_voxel, total_ms, VOXEL_SIZE, VOXEL_RES])
	_busy = false


func _log(msg: String) -> void:
	if table != null:
		table.text = msg


# ================================================================== 相机

func _apply_sky() -> void:
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.42, 0.58, 0.80)
	mat.sky_horizon_color = Color(0.88, 0.91, 0.95)
	sky.sky_material = mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom = clampf(_zoom * 0.9, 0.15, 6.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom = clampf(_zoom * 1.1, 0.15, 6.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.006
		_pitch = clampf(_pitch - mm.relative.y * 0.006, -1.45, 1.45)
		_update_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_R:
			_seed += 1
			_rebuild()


func _update_camera() -> void:
	## 距离吃 _span 与 zoom：排布越长越远，滚轮再在其基础上微调
	camera.position = _center + Vector3(
		sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * (_span * _zoom)
	camera.look_at(_center, Vector3.UP)


## 供冒烟测试：跑一遍并确认至少一半生成器产出了网格。
func smoke_test() -> bool:
	var n := 0
	for c in world.get_children():
		if String(c.name).ends_with("_mesh"):
			n += 1
	return n * 2 >= GENS.size()
