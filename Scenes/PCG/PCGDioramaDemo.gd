extends Node3D

## 用例四「体素面包店街角」演示场景
##
## ============================ 这个场景证明什么 ============================
## 1. **一份生成数据 → 一块展示底座上的完整街角**。9 个 [PropGen] 各自的形状只由
##    自己的 [method PropGen.build] 决定；"谁站哪、谁朝向哪"全部来自
##    [DioramaPresets] 的配方表。改一个半径就换布局，不会碰到任何几何代码。
##
## 2. **体素分色真的显示出来了**。[method PropGen.voxel_regions] 声明的部位索引
##    经 [method ToonMaterial.voxel_material_provider] 变成"逐索引一份材质"，
##    贪心网格每个调色板槽位一个 surface，于是屋顶是陶红、窗是暖黄、树干是棕色。
##    传单个 [Material] 的话这些 surface 会挂同一个主色 —— 画面照样出图，
##    只是"整体一个颜色"，**不报任何错**。切"网格"按钮能看出对比：
##    网格形态没有部位色通道，墙是一整片单色。
##
## 3. **全场方块边长一致**。所有配方只填 [member DioramaRecipe.voxel_cell]（0.2 米），
##    由各物体自己的尺寸反推 voxel_res；再加上 [member DioramaDef.voxel_grid_snap]
##    把落位吸附到同一套格点。切到"逐块方块"能一眼验证这件事：
##    屋顶的砖和邮筒的边是同一个尺寸的方块。
##
## 4. **完整度自检可执行**。[method DioramaBuild.validate] 把"底座 / 主体 / 环境 /
##    道具 / 体素是否齐全"变成日志里的一行字，而不是靠人数物件。
##
## 操作：左键拖拽旋转 / 滚轮缩放 / 顶部按钮切投影形态 / R 换种子

## 投影形态按钮的取值。
const FORM_GREEDY := 0   ## 体素 · 贪心合并（面色干净、面数低，默认）
const FORM_ITEM := 1     ## 体素 · 逐块方块（Minecraft 观感，验证"统一正方体"）
const FORM_MESH := 2     ## 光滑等值面网格（对照：没有部位色通道）

## 基准视场角。与预设各自的 `view.dist` 一起构成"长焦后退"的换算基准：
## 实际 FOV 取 [member SceneStylePack.camera_fov]，相机同步退到
## `BASE_DIST * frame_scale(FOV, 基准)`，于是画面里主体的大小不变、只有透视被压扁。
const BASE_FOV := 70.0

@export var preset_key: StringName = &"steam_dock"

@onready var world: Node3D = %World
@onready var camera: Camera3D = %Camera3D
@onready var key_light: DirectionalLight3D = %KeyLight
@onready var env_node: WorldEnvironment = %Env
@onready var title: Label = %Title
@onready var log_box: Label = %Log
@onready var hint: Label = %Hint
@onready var row_form: HBoxContainer = %RowForm

## —— 相机 ——
var _yaw := PI          ## 镜头在 -Z 侧（背板弧心在 +Z，主体朝 -Z）
var _pitch := 0.62      ## 俯角。0.40 太低：圆形底座只露一条弧边，"展示底座"这个
                        ## 微缩场景的核心识别特征基本看不见（实测截图）
var _zoom := 1.0
## 视点抬高到树冠高度，让底座圆盘能完整入画
var _look_at := Vector3(0.0, 3.0, -0.8)
## 基准取景距离（米）。每幅 diorama 的包围盒不同，由预设的 `view.dist` 给定。
var _base_dist := 19.0
var _dragging := false

## —— 微缩三要素（长焦 / 景深 / 暗角）——
## 只借 [MiniatureStage] 的镜头与暗角两段，**不碰它的 [method MiniatureStage.apply_environment]**：
## 那段会连配色一起接管，而本场景的固有色必须留在 [VoxelSkin] 的 17 色 swatch 上
## （见 [method _setup_stage] 的说明）。所以这里自建一个只填镜头/暗角字段的包。
var _lens: SceneStylePack = null

## —— 场景 ——
## 当前这幅 diorama 的全部内容（def / recipes / skin / style / view / env，
## 见 [method DioramaPresets.presets]）。本场景不存任何"某一幅画"的判断。
var _pack: Dictionary = {}
var _skin: DioramaSkin = null
var _style: ToonStyleDef = null
var _palette: ToonPaletteDef = null
var _def: DioramaDef = null
var _recipes: Array = []
var _builder = null
var _build = null
var _seed := 20261002
var _form := FORM_GREEDY
var _busy := false

## 逐索引材质提供者（懒建于首次渲染，避免 _ready 里就造满一整套 ShaderMaterial）
var _provider: Callable = Callable()


func _ready() -> void:
	_apply_preset(preset_key)
	_build_buttons()
	_update_camera()
	_assemble()


## 换一幅 diorama。画风、配色、取景、后期**全部**来自预设 ——
## 加一个新用例只需要往 [method DioramaPresets.presets] 里添一项，本文件不用动。
func _apply_preset(key: StringName) -> void:
	preset_key = key
	var all := DioramaPresets.presets()
	_pack = all.get(key, all[all.keys()[0]])
	_skin = _pack.get(&"skin", null) as DioramaSkin
	_style = _pack.get(&"style", null) as ToonStyleDef
	if _style == null:
		_style = ToonStyleDef.presets()[&"miniature_diorama"]
	_palette = _skin.palette() if _skin != null else ToonPaletteDef.new()
	## 取景：俯角与视点高度每幅不同 —— 面包店 7.9 米高、村庄塔顶 5.0 米，
	## 共用一组（0.62 / y=3.0）会让矮的那幅只看见一条地平线。
	var view: Dictionary = _pack.get(&"view", {})
	_base_dist = float(view.get(&"dist", 19.0))
	_look_at = view.get(&"look", Vector3(0.0, 3.0, -0.8))
	_pitch = float(view.get(&"pitch", 0.62))
	_yaw = float(view.get(&"yaw", PI))
	## 换画即换色板：旧的逐索引材质必须作废，否则新场景会挂上旧画的 17 色
	## —— 表现是"村子的树是奶油色的"，且不报任何错。
	_provider = Callable()
	_setup_stage()


# ================================================================== 舞台

## 舞台三件套：主光（方向**必须**与色阶的 key_light_dir 同向）、环境、相机。
##
## 为什么不复用 [method MiniatureStage.apply]：那份方法连**配色方案**一起接管，
## 而本场景的固有色来自 [VoxelSkin] 的 17 色 swatch（体素分件索引表），
## 两套配色同时在场只会让"颜色到底从哪来"变得不可追。
## 所以只借它的镜头与暗角两段（见 [method _setup_lens]），环境仍由本函数自建。
func _setup_stage() -> void:
	if key_light != null:
		## [method ToonStyleDef.key_light_position] 给的是"光该站哪"，
		## 朝向交给 look_at —— 引擎的 -Z 出光约定不必在调用方手里绕一遍。
		key_light.position = _style.key_light_position(20.0)
		key_light.look_at(Vector3.ZERO, Vector3.UP)
		key_light.light_color = _style.key_light_color
		key_light.light_energy = 1.15
		key_light.shadow_enabled = true
	if env_node != null:
		var e := Environment.new()
		e.background_mode = Environment.BG_COLOR
		## 背景色**不用** [member ToonStyleDef.fog_color]：雾色是"远处物体被拉向的颜色"，
		## 它必须比主体亮一档才推得动；而背景是"主体背后那块布"，必须比主体暗一档
		## 才托得住。两者同色时奶白墙会与背景糊在一起（实测截图：整张画面没有轮廓）。
		var env_bd: Dictionary = _pack.get(&"env", {})
		e.background_color = env_bd.get(&"backdrop",
			_style.fog_color.lerp(Color(0.10, 0.12, 0.18), 0.55))
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = _style.ambient
		e.ambient_light_energy = _style.ambient_energy
		## 雾是"微缩感"的来源：把 12 米的街角压成桌面上一块 30 厘米的摆件。
		## 但**只由着色器那一层负责**（[member ToonStyleDef.fog_density] →
		## `u_fog_density`），不开Godot 原生雾：原生雾是屏幕空间深度混合，会无差别
		## 把整个画面（含高明度的奶白墙体）拉向背景色，与着色器雾叠成两层同密度雾，
		## 实测把用例四整张画面烧成近白。
		e.fog_enabled = false
		## —— 曝光与后期调色：这一段漏了会把整张画面烧成白纸——
		## [method MiniatureStage.apply] 本来会配好它，但本场景刻意不走那份（配色
		## 来源会打架），于是**连后期一起漏掉了**，只剩 `Environment.new()` 的默认值：
		## 曝光 1.0 + 后期调色关闭。而三渲二靠的是**硬边色阶**，必须保留线性 tonemap
		## （换 AgX/Filmic 会把色阶的对比抹平），代价就是线性**没有高光滚降**：
		## 本场景固有色整体高明度（奶白墙 0.95）、主光近白、环境光 0.42，三者相乘
		## 直接越过 1.0 被 clip —— 屏幕上色相全部丢失，就是"烘焙正常、几何正常、
		## 网格与体素两种形态都对，却糊成一张没有颜色的白纸"。
		## 所以这里降曝光把峰值拉回线性范围（顺带让背景色比主体暗一档，
		## 奶白墙得以从背景里跳出来），再补回调色：饱和度略升把三渲二的大平色
		## 从"塑料"拉回"插画"。数值来自 [member SceneStylePack.env_saturation] 一档。
		## 曝光与饱和度由预设的 `env` 给：高明度色板（面包店奶白 0.95）
		## 需要压到 0.75，中明度的（村庄草地 0.48~0.7）压到 0.88 就够 ——
		## 一幅画一套，没有通用值。
		var env_cfg: Dictionary = _pack.get(&"env", {})
		e.tonemap_exposure = float(env_cfg.get(&"exposure", 0.80))
		e.adjustment_enabled = true
		e.adjustment_contrast = float(env_cfg.get(&"contrast", 1.05))
		e.adjustment_saturation = float(env_cfg.get(&"saturation", 1.10))
		## SSAO 会在色阶交界糊出一圈脏灰（把两档色糊成三档脏色），glow 会让描边与
		## 高光溢出轮廓糊成一团。两者都不报错、只是"看着不对"，所以显式关掉。
		e.ssao_enabled = false
		e.glow_enabled = false
		env_node.environment = e
	_setup_lens()


## 装上微缩感三要素里缺的两项：长焦（相机 FOV）与边缘收暗（暗角层），外加景深。
##
## 之前只有雾，雾只能"把远处压低对比"，出不来"照片感"——
## 实测画面是一张均匀发白的游戏截图，而不是"桌上拍的树脂模型"。
## 三要素的物理分工见 [MiniatureStage] 文件头。
func _setup_lens() -> void:
	_lens = SceneStylePack.new()
	## ① 长焦：28° 压缩透视（微缩三要素之一，另两个是景深与暗角）。
	## 代价是画面会"凑近"，所以相机距离必须同步乘 [method MiniatureStage.frame_scale]，
	## 由 [method _update_camera] 负责 —— 少了这步，换来的就是一次突兀的推近。
	var lens_cfg: Dictionary = _pack.get(&"env", {})
	_lens.camera_fov = float(lens_cfg.get(&"fov", 28.0))
	## ② 景深。**虚化起点必须跟着场景尺度改**：[SceneStylePack] 默认 55 米是给街景的，
	## 而长焦把相机推到了 50 米开外，不改的话整幅画恰好全落在焦点内 ⇒ 虚化等于没开。
	var cam_dist := _base_dist * MiniatureStage.frame_scale(_lens.camera_fov, BASE_FOV)
	_lens.dof_amount = float(lens_cfg.get(&"dof", 0.55))
	## 远景虚化起点要落在**场景后沿之外**：场景在相机前方 52 m 处、半径约 10 m，
	## 起点设成 cam_dist + 1 等于把整个场景推进过渡带里 —— 实测画面只剩一团糊光。
	_lens.dof_far_distance = cam_dist + 12.0
	_lens.dof_far_transition = 14.0
	## ③ 边缘收暗。Godot 的 Environment **没有暗角项**，只能自己画一层屏幕空间遮罩。
	MiniatureStage.apply_camera(camera, _lens)
	MiniatureStage.apply_vignette(self, _lens)


# ================================================================== 组装

func _assemble() -> void:
	if _busy:
		return
	_busy = true
	_def = _pack.get(&"def", null)
	_recipes = _pack.get(&"recipes", [])
	_clear_world()
	if _def == null:
		_busy = false
		return

	## 分帧烘焙：一次跑完会白屏十几秒，且期间 current_scene 可能还没切好，
	## 自动化工具会据此误判为崩溃（见 [DioramaBuilder] 文件头的"分帧"小节）。
	_builder = DioramaBuilder.new()
	_builder.begin(_def, _recipes, _seed)
	var bake_ms := 0
	var frames := 0
	while true:
		var t0 := Time.get_ticks_msec()
		var done: bool = _builder.step()
		bake_ms += Time.get_ticks_msec() - t0
		if done:
			break
		frames += 1
		_log("烘焙中… 剩余 %d 个单体 ｜ 已用 %d ms" % [_builder.pending(), bake_ms])
		await get_tree().process_frame
	_build = _builder.finish()

	_render()
	_spawn_accent_lights()
	_busy = false

	## 完整度自检 + 体素统计都进日志：这四项缺失时画面**不会崩、只会安静地少东西**，
	## 光看截图无法归因，必须有一行可读的数字自证。
	var bad: Array = _build.validate()
	_log("%s ｜ 种子 %d ｜ %s ｜ 底座半径 %.1f m%s" % [
			_def.get_desc(null), _seed, _build.story(), _def.base_radius(),
			("" if bad.is_empty() else " ｜ ⚠ 完整度：%s" % ", ".join(bad))])
	if title != null:
		title.text = "%s ｜ 种子 %d ｜ %s" % [
			_skin.title if _skin != null else preset_key, _seed, _form_name()]
	if hint != null:
		hint.text = "左键拖拽旋转 ｜ 滚轮缩放 ｜ R 换种子 ｜ 目标体素边长 %.2f m（全场统一，吸附格点 %.2f m）" % [
			float(_pack.get(&"cell", 0.12)), _def.voxel_grid_snap]
	print("[PCGDioramaDemo] %s ｜ 烘焙 %d ms（分 %d 帧）｜ 完整度问题 %s" % [
		_build.story(), bake_ms, frames, str(bad)])


func _clear_world() -> void:
	for c in world.get_children():
		c.queue_free()


## 摆进场景树。
##
## 走 [method DioramaBuilder.spawn] 而不是自己遍历 [method DioramaBuild.all]：
## 底座与全部摆位的 xform 都由它负责，自己遍历很容易漏掉底座（它不在
## subjects/env/props 任何一组里，而是 [member DioramaBuild.base]）。
func _render() -> void:
	if _provider.is_null() or not _provider.is_valid():
		_provider = _skin.material_provider(_style) if _skin != null \
			else ToonMaterial.voxel_material_provider(_style, _palette)
	var form := _prop_form()
	var root := DioramaBuilder.spawn(_build, world, _provider, form)
	root.name = "Diorama"
	## 描边单独一轮：体素网格的材质已由 provider 逐槽位给过，
	## [method ToonMaterial.apply] 必须带 keep_material —— 否则统一赋值会把
	## 所有部位压成同一个主色，而**画面照样出图、不报任何错**。
	for c in root.get_children():
		var mi := c as MeshInstance3D
		if mi != null:
			ToonMaterial.apply(mi, _style, _palette, mi, false, null, true)


## 把 [member DioramaDef.accent_lights] 的声明变成真正的 [OmniLight3D]。
##
## 框架层只负责**声明**这份表（[DioramaDef] 里没有任何创建节点的代码），
## 真正落地是场景的职责 —— 与 [member DioramaDef.base_gen] 同一分工。
func _spawn_accent_lights() -> void:
	if _def == null:
		return
	var host := Node3D.new()
	host.name = "AccentLights"
	world.add_child(host)
	for i in _def.accent_lights.size():
		var cfg: Dictionary = _def.accent_lights[i]
		var l := OmniLight3D.new()
		l.name = "Accent%d" % i
		l.light_color = cfg.get(&"color", Color.WHITE)
		l.light_energy = float(cfg.get(&"energy", 1.0))
		l.omni_range = float(cfg.get(&"radius", 2.0))
		var off: Vector3 = cfg.get(&"offset", Vector3.ZERO)
		l.position = off + Vector3(0.0, float(cfg.get(&"height", 2.0)), 0.0)
		l.shadow_enabled = false      ## 氛围灯不投影：点光阴影会把体素硬边糊掉
		host.add_child(l)


# ================================================================== UI

func _build_buttons() -> void:
	if row_form == null:
		return
	## 用例切换行：从预设表自动生成，加一个新用例不用改本文件。
	## 插在形态行之前 —— 先选"看哪一幅"，再选"以什么形态看"。
	var parent := row_form.get_parent()
	if parent != null:
		var rowp := HBoxContainer.new()
		rowp.name = "RowPreset"
		rowp.add_theme_constant_override("separation", 6)
		parent.add_child(rowp)
		parent.move_child(rowp, row_form.get_index())
		for k in DioramaPresets.presets().keys():
			var skin: DioramaSkin = DioramaPresets.presets()[k].get(&"skin", null)
			var b := Button.new()
			b.text = skin.title if skin != null else String(k)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var key: StringName = k
			b.pressed.connect(func():
				if key == preset_key:
					return
				_apply_preset(key)
				_assemble())
			rowp.add_child(b)
	for c in row_form.get_children():
		c.queue_free()
	for item in [["体素·贪心", FORM_GREEDY], ["体素·逐块", FORM_ITEM], ["网格对照", FORM_MESH]]:
		var b := Button.new()
		b.text = item[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var v: int = item[1]
		b.pressed.connect(func():
			_form = v
			_assemble())
		row_form.add_child(b)


func _form_name() -> String:
	match _form:
		FORM_ITEM: return "体素·逐块方块"
		FORM_MESH: return "光滑网格"
		_: return "体素·贪心合并"


## 按钮取值 → [enum PropBuild.Form]。
##
## 网格对照用 [constant Form.MESH] 而不是 [constant Form.AUTO]：
## AUTO 会在网格非空时优先走网格、在网格空时退回体素，
## 那就变成了"大多数单体是网格、少数是体素"的混合场景，对照不出任何东西。
func _prop_form() -> int:
	match _form:
		FORM_ITEM: return PropBuild.Form.VOXEL_ITEM
		FORM_MESH: return PropBuild.Form.MESH
		_: return PropBuild.Form.VOXEL_GREEDY


# ================================================================== 相机

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom = clampf(_zoom * 0.9, 0.35, 2.6)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom = clampf(_zoom * 1.1, 0.35, 2.6)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.006
		_pitch = clampf(_pitch - mm.relative.y * 0.006, -1.35, 1.35)
		_update_camera()
	elif event is InputEventKey and event.pressed and not event.is_echo():
		if (event as InputEventKey).keycode == KEY_R:
			_seed += 1
			_assemble()


func _update_camera() -> void:
	## 长焦要同步后退，否则 FOV 一变小画面就"猛地凑近"。
	## 倍率由 [method MiniatureStage.frame_scale] 给出（70° → 28° 约 2.75 倍）。
	var fov := camera.fov if _lens != null else BASE_FOV
	var dist := _base_dist * MiniatureStage.frame_scale(fov, BASE_FOV) * _zoom
	camera.position = _look_at + Vector3(
		sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * dist
	camera.look_at(_look_at, Vector3.UP)


func _log(msg: String) -> void:
	if log_box != null:
		log_box.text = msg


## 供 TestRunner / 自动化冒烟：跑一次完整组装并确认完整度无问题。
func smoke_test() -> bool:
	return _build != null and _build.validate().is_empty()
