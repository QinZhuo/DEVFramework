extends Node3D

## 教程演示 — 覆盖各种目标形态, 表现全部交给 FocusMask(全场变暗, 只有目标亮着):
##   1. 静态 2D 按钮(主视口)
##   2. 3D 球体(主世界, 重新渲染到暗区之上)
##   3. 缓慢移动的 2D 按钮(可交互区每帧跟随)
##   4. SubViewport 里的 2D 按钮(经 SubView3D 渲染到 3D 屏幕)
##   5. SubViewport 里的 3D 方块(子视口独立世界)
##   6. 多目标同框(两个按钮都可点, 点任一推进)
##   7. 无目标纯提示(全屏变暗, 点屏幕任意处继续)

const TUTORIAL := preload("res://Assets/Def/Tutorial/Tutorial_Start.tres")

@onready var _hint: Label = $UI/Hint
@onready var _moving: Button = $UI/MovingButton

var _guide: TutorialGuide
var _task: GroupTask
var _moving_origin := Vector2.ZERO
var _move_time := 0.0


func _ready() -> void:
	TranslationTool.initialize()  # 加载 Assets/Translation 翻译(task.csv.zh.translation)
	_build_screens()
	_moving_origin = _moving.position
	_guide = TutorialGuide.new()
	_guide.name = "TutorialGuide"
	add_child(_guide)
	_task = _guide.start(TUTORIAL, self)  # 一行启动(步骤推进 → 聚焦表现在 Guide 内部)
	_task.completed.connect(_on_completed)
	_task.progress_changed.connect(_on_progress_changed)


## 演示"高亮跟随移动目标": 按钮在屏幕上来回缓慢移动, 可交互区每帧自动重算
func _process(delta: float) -> void:
	_move_time += delta
	_moving.position = _moving_origin + Vector2(sin(_move_time * 0.8) * 90.0, cos(_move_time * 0.6) * 24.0)


## 两块 3D 屏幕: 左边子视口放 2D UI, 右边子视口放独立 3D 世界
func _build_screens() -> void:
	var screen2d := TutorialScreen3D.new()
	screen2d.name = "Screen2D"
	screen2d.background = Color(0.16, 0.24, 0.4)  # 不透明彩色底: 压暗后仍应只亮按钮
	screen2d.position = Vector3(-1.9, 1.0, 0.4)
	screen2d.rotation_degrees = Vector3(0, 20, 0)
	add_child(screen2d)
	var ui := Control.new()
	ui.name = "ScreenUI"
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen2d.viewport.add_child(ui)
	var btn := Button.new()
	btn.name = "ScreenBtn"
	btn.text = "屏幕按钮"
	btn.size = Vector2(150, 46)
	btn.position = (Vector2(screen2d.viewport_size) - btn.size) * 0.5
	ui.add_child(btn)

	var screen3d := TutorialScreen3D.new()
	screen3d.name = "Screen3D"
	screen3d.own_world = true
	screen3d.background = Color(0.34, 0.12, 0.16)  # 3D 屏幕也带不透明彩色底
	screen3d.position = Vector3(1.9, 1.0, 0.4)
	screen3d.rotation_degrees = Vector3(0, -20, 0)
	add_child(screen3d)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 1.4)
	cam.current = true
	screen3d.viewport.add_child(cam)
	var cube := ButtonView3D.new()  # 3D 可点击物体统一用框架的 ButtonView3D
	cube.name = "Cube"
	var box := BoxMesh.new()
	box.size = Vector3(0.42, 0.42, 0.12)
	var cube_mesh := MeshInstance3D.new()
	cube_mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.55, 0.2)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cube_mesh.material_override = mat
	cube.add_child(cube_mesh)
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.42, 0.42, 0.12)
	var cube_shape := CollisionShape3D.new()
	cube_shape.name = "CollisionShape3D"  # ButtonView3D 按此名取碰撞
	cube_shape.shape = shape
	cube.add_child(cube_shape)
	screen3d.viewport.add_child(cube)  # 子树建完再入树, 保证 _ready 时子节点已就位

	# 嵌套子视口: 主窗口 → 外层屏幕(自己的 3D 世界) → 内层面板 → 内层 2D 按钮
	# 对应"3D 世界本身渲染在 SubViewport 里, 里面还有一块贴图面"的项目结构
	var nest := TutorialScreen3D.new()
	nest.name = "ScreenNest"
	nest.own_world = true
	nest.background = Color(0.12, 0.14, 0.2)
	nest.position = Vector3(0, 2.15, 0.2)
	nest.rotation_degrees = Vector3(-8, 0, 0)
	add_child(nest)
	var nest_cam := Camera3D.new()
	nest_cam.position = Vector3(0, 0, 2.2)
	nest_cam.current = true
	nest.viewport.add_child(nest_cam)
	var nest_light := DirectionalLight3D.new()
	nest_light.rotation_degrees = Vector3(-40, 25, 0)
	nest.viewport.add_child(nest_light)

	var inner := SubView3D.new()
	inner.name = "InnerPanel"
	var inner_vp := SubViewport.new()
	inner_vp.name = "InnerViewport"
	inner_vp.size = Vector2i(320, 200)
	inner_vp.transparent_bg = false  # 不透明底: 最容易被"整块亮"坑到
	inner_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	inner.add_child(inner_vp)
	var inner_bg := ColorRect.new()
	inner_bg.name = "InnerBackdrop"
	inner_bg.color = Color(0.2, 0.16, 0.28)
	inner_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inner_vp.add_child(inner_bg)
	var inner_btn := Button.new()
	inner_btn.name = "NestedBtn"
	inner_btn.text = "嵌套按钮"
	inner_btn.position = Vector2(90, 70)
	inner_btn.size = Vector2(140, 60)
	inner_vp.add_child(inner_btn)
	inner.viewport = inner_vp
	nest.viewport.add_child(inner)


## 进度变化 → 刷新步骤计数
func _on_progress_changed() -> void:
	var p := _task.get_progress()
	_hint.text = "教程进度: %d/%d" % [p.x, p.y]


func _on_completed() -> void:
	# 延迟到 progress_changed 之后, 免得状态文字被"进度: n/n"覆盖
	_set_hint_later.call_deferred("教程完成! 可再次运行场景重新体验。")
	print("[TutorialDemo] 教程完成")


func _set_hint_later(text: String) -> void:
	_hint.text = text
