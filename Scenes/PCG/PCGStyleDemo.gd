extends Node3D

## 风格场景演示 —— **一个场景看遍三套画风，同一份数据可落成网格或体素**
##
## ============================ 这个场景证明什么 ============================
## 1. **换风格包 = 换整个场景**。点一个按钮，画风、配色、内容组合、布局参数、
##    输出形态一起变。三者不再是散在三个地方手动凑的参数。
##
## 2. **一份烘焙数据，两种模型**。[method ModelBaker] 与 [PropGenDef] 的双产物设计
##    让同一个单体同时给出 lowpoly 网格与体素网格，两者**共用同一次场烘焙**，
##    所以切到"两者"模式看到的不是两个模型在对齐，而是**同一个模型的两种解读**。
##
## 3. **全程无贴图**。色阶 / 描边 / 轮廓光 / 雾全部由 [ToonShader] 与
##    [ToonStyleDef] 给，材质表现干净、轮廓明确 —— 这正是三渲二与 PBR 的分界线。
##
## 4. **切风格包连镜头一起切**。三套预设的长焦 / 景深 / 背景 / 暗角各不相同
##    （见 [MiniatureStage]），由 `pack.apply_stage()` 一次装好。切到"微缩童话"
##    时画面会变成"长焦 + 浅景深 + 收暗边缘"，而不是同一堆模型换层皮。
##
## 操作：左键拖拽旋转 / 滚轮缩放 / 顶部按钮切换风格与输出形态 / R 换种子

## 输出形态常量。与 [code]SceneStylePack.Output[/code] 一一对应，
## 这里写成字面量是刻意的：新脚本的 class_name 未必已进全局类表，
## 引用它的枚举会让本场景在编辑器尚未扫描时直接编译失败。
const OUT_MESH := 0
const OUT_VOXEL := 1
const OUT_BOTH := 2

## 基准取景距离（米），按 **70° 默认视场角**下的距离标定。
## 风格包的长焦 FOV 会让画面猛地凑近，`apply_stage` 据此换算出的
## `stage_distance_hint` 才是实际相机距离 —— 否则切风格包时观众看到的是"突然变焦"。
const BASE_DIST := 62.0

@export var pack_key: StringName = &"jp_street"

@onready var camera: Camera3D = %Camera3D
@onready var world: Node3D = %World
@onready var title: Label = %Title
@onready var log_box: Label = %Log
@onready var hint: Label = %Hint
@onready var row_style: HBoxContainer = %RowStyle
@onready var row_out: HBoxContainer = %RowOut
@onready var btn_regen: Button = %Regen

## —— 相机 ——
var _yaw := 0.85
var _pitch := 0.52
var _zoom := 1.0
var _look_at := Vector3(20.0, 1.5, -8.0)
var _dragging := false
var _press_pos := Vector2.ZERO

## —— 场景 ——
var _pack = null
var _asm = null
var _placements: Array = []
var _seed := 20261002
var _out := -1          ## -1 = 用风格包自己的默认
var _busy := false

const PACK_PATH := "res://Scripts/Gen/SceneStylePresets.gd"

## 地面恒为平面：微缩模型是摆在台面上的，起伏地形会把"可收藏感"冲掉。
static func _ground_y(_x: float, _z: float) -> float:
	return 0.0

func _ready() -> void:
	_build_buttons()
	_pick_pack(pack_key)
	_update_camera()
	if btn_regen != null:
		btn_regen.pressed.connect(func(): _seed += 1; _assemble())

# ================================================================== 风格包

func _picks() -> Dictionary:
	return load(PACK_PATH).new().presets()

func _pick_pack(k: StringName) -> void:
	## 风格包换了，装配器必须重建 —— 它缓存的是上一套配方的烘焙结果。
	_pack = _picks()[k]
	pack_key = k
	_asm = null
	_build_base()
	_apply_stage()
	_assemble()

## 把风格包的镜头 / 环境 / 暗角装到场景里。
##
## `apply_stage` 内部会顺手算好 `stage_distance_hint`（长焦该退多远），
## 所以这里紧接着就要 `_update_camera()` —— 顺序反了会出现
## "切完风格包画面还停在旧景别上，等滚轮一动才跳"。
func _apply_stage() -> void:
	if _pack == null:
		return
	## `apply_stage` 内部会一并把主光对准 `style.key_light_dir`
	## （见 [MiniatureStage.apply_key_light]：色阶方向是 uniform，实灯必须跟着走，
	##  否则色阶亮面与实灯亮面错开一道，硬边阴影与色阶互相打架且不报错）。
	_pack.apply_stage(self, camera, BASE_DIST)
	_update_camera()

func _build_buttons() -> void:
	if row_style == null:
		return
	for c in row_style.get_children():
		c.queue_free()
	for k in _picks().keys():
		var p = _picks()[k]
		var b := Button.new()
		b.text = p.title
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): _pick_pack(k))
		row_style.add_child(b)
	if row_out == null:
		return
	for c in row_out.get_children():
		c.queue_free()
	for item in [["网格", OUT_MESH], ["体素", OUT_VOXEL], ["两者对照", OUT_BOTH]]:
		var b := Button.new()
		b.text = item[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var v: int = item[1]
		b.pressed.connect(func(): _out = v; _assemble())
		row_out.add_child(b)

# ================================================================== 台座

## 微缩感的来源之一：物体**摆在台面上**，而不是长在地里。
## 用原生 [CylinderMesh] 而不是手写顶点 —— Godot 已有现成的就别自己搭。
func _build_base() -> void:
	for c in world.get_children():
		if c.name == "Base":
			c.queue_free()
	var is_mini := (_pack != null and String(pack_key) == "mini_fairy")
	var radius := 26.0 if is_mini else 60.0
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius * 1.05
	cyl.height = 1.2
	cyl.radial_segments = 64
	var mi := MeshInstance3D.new()
	mi.name = "Base"
	mi.mesh = cyl
	mi.position = Vector3(_look_at.x, -0.62, _look_at.z)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.88, 0.86, 0.82) if is_mini else Color(0.55, 0.62, 0.52)
	m.roughness = 1.0
	mi.material_override = m
	world.add_child(mi)

# ================================================================== 组装

func _assemble() -> void:
	if _busy or _pack == null:
		return
	_busy = true
	_clear_world()
	if _asm == null:
		_asm = WorldAssembler.from_pack(_pack, Callable(self, "_ground_y"))

	var bake_ms := 0
	var frames := 0
	while true:
		var s0 := Time.get_ticks_msec()
		## 用 `=` 而非 `:=`：_asm / _pack 是 Variant（风格包靠运行时 load 取得），
		## 编译器无法推断其方法返回类型，`var done :=` 会直接解析失败。
		var done = _asm.assemble_step(_seed)
		bake_ms += Time.get_ticks_msec() - s0
		if done:
			break
		frames += 1
		_log("烘焙中… 剩余 %d 个单体 ｜ 已用 %d ms" % [_asm.step_pending(), bake_ms])
		await get_tree().process_frame

	_placements = _asm.assemble_finish(_seed)
	_render(_placements)
	_busy = false

	title.text = "%s ｜ 种子 %d" % [_pack.title, _seed]
	## 回退数量挂进日志而不是只留在代码里：一旦"体素形态"看起来少了东西，
	## 这里必须能一眼看出是**哪些单体没被体素化**，而不是让人去猜。
	## 镜头参数同样入日志：微缩感三要素任一为 0，画面就会退回"游戏截图"，
	## 而这既不报错也不崩，只能靠这一行数字自证。
	var extra := ("｜ %d 个无体素产物，回退网格" % n_fallback) if n_fallback > 0 else ""
	_log("%s ｜ %d 个单体 ｜ 网格 %d ｜ 体素 %d%s ｜ 长焦 %.0f° 虚化 %.2f 暗角 %.2f ｜ 烘焙 %d ms（分 %d 帧）" % [
		_pack.title, _placements.size(), _n_mesh, _n_vox, extra,
		_pack.camera_fov, _pack.dof_amount, _pack.vignette_strength, bake_ms, frames])
	if hint != null:
		hint.text = _pack.desc

func _clear_world() -> void:
	## 保留台座 —— 否则重新烘焙的十几秒里画面是空的
	for c in world.get_children():
		if c.name != "Base":
			c.queue_free()

## 上一次渲染的产物计数。GDScript 没有 out 参数，故用实例变量回传。
var _n_mesh := 0
var _n_vox := 0
## 体素形态下回退成网格的单体数（扁长路面等无法体素化的物体）。
var n_fallback := 0

func _render(placements: Array) -> void:
	var out := _out if _out >= 0 else int(_pack.output)
	var shift := Vector3(70.0, 0.0, 0.0) if out == OUT_BOTH else Vector3.ZERO
	var n_mesh := 0
	var n_vox := 0
	n_fallback = 0
	for p in placements:
		var pl: PropLayoutTool.Placement = p
		if pl == null or pl.build == null:
			continue
		var tag := String(pl.meta.get(&"tag", "prop"))
		var has_vox := pl.build.has_voxel()

		## 体素形态下若某个单体没有体素产物，**回退到网格**，绝不凭空消失。
		## 典型受害者是街道：`voxel_res` 按最长边定尺，而路面是 24 × 0.6 × 10.8 米的
		## 扁长体，短边只剩一两格，体素化直接退化。把这些静默跳过的话，
		## 切到体素形态会看见**底座凭空消失、所有模型悬在半空**，而日志一片正常。
		var fallback := out == OUT_VOXEL and not has_vox
		if fallback:
			n_fallback += 1

		if out != OUT_VOXEL or fallback:
			var mi := pl.instantiate(null)
			if mi != null:
				mi.name = "%s_%d" % [tag, pl.seed_value]
				world.add_child(mi)
				## 材质由风格包统一给 —— 不读配方里的 sharp_normal/sharpen，
				## 否则同一场景会出现两种描边粗细。
				_pack.apply_material(mi)
				n_mesh += 1

		if out != OUT_MESH and has_vox:
			var vn = ModelBaker.build_voxel_node(pl.build.voxel, {
				"style": _pack.style,
				"palette": _pack.palette,
				"greedy": _pack.greedy,
				"name": "%s_vox_%d" % [tag, pl.seed_value],
			})
			vn.transform = pl.xform
			vn.position += shift
			world.add_child(vn)
			n_vox += 1
	_n_mesh = n_mesh
	_n_vox = n_vox

# ================================================================== 相机

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
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.006
		_pitch = clampf(_pitch - mm.relative.y * 0.006, -1.45, 1.45)
		_update_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_R:
			_seed += 1
			_assemble()

func _update_camera() -> void:
	## 距离用风格包算出的长焦距离（`stage_distance_hint`），没有则退回基准值。
	## 两者的差别就是"微缩感三要素之①长焦" —— 同样的模型，长焦一压透视就出来了。
	var base := BASE_DIST
	if _pack != null and _pack.stage_distance_hint > 0.0:
		base = _pack.stage_distance_hint
	var dist := base * _zoom
	camera.position = _look_at + Vector3(
		sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * dist
	camera.look_at(_look_at, Vector3.UP)

func _log(msg: String) -> void:
	if log_box != null:
		log_box.text = msg

## 供 TestRunner / 自动化冒烟：跑一次完整组装并确认可用。
func smoke_test() -> bool:
	_assemble()
	return _placements.size() >= 2
