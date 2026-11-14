class_name TutorialScreen3D extends Node3D
## 演示: 3D 世界里的一块"屏幕" — SubViewport 渲染到贴图面, 并把指针转发进子视口。
## 用来验证"子视口里的 2D / 3D 目标"也能被 FocusMask 算成正确的屏幕区域。
## 结构约定(与 FocusMask 的子视口换算一致): SubViewport 是 SubView3D 的子节点。

## 贴图面尺寸(米)
var panel_size := Vector2(1.4, 1.05)
## 子视口分辨率
var viewport_size := Vector2i(448, 336)
## 3D 内容需要独立世界(否则会去渲染主世界)
var own_world := false
## 屏幕底色: 2D 内容铺 ColorRect, 3D 内容用 WorldEnvironment(都是不透明底)
var background := Color(0.08, 0.11, 0.18)

var viewport: SubViewport
var screen: SubView3D
var area: Area3D


func _ready() -> void:
	# 指针转发: 打在面板上的事件换算成子视口坐标再投递(3D 内容靠它做物理拾取)
	var shape := BoxShape3D.new()
	shape.size = Vector3(panel_size.x, panel_size.y, 0.04)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	area = Area3D.new()
	area.name = "ScreenArea"
	area.add_child(collision)
	add_child(area)

	var quad := QuadMesh.new()
	quad.size = panel_size
	screen = SubView3D.new()
	screen.name = "Screen"
	screen.mesh = quad
	screen.area = area
	screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(screen)

	viewport = SubViewport.new()
	viewport.name = "SubViewport"
	viewport.size = viewport_size
	viewport.transparent_bg = not own_world  # 2D 屏幕自己铺底, 3D 用环境底色
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = own_world
	viewport.physics_object_picking = own_world
	screen.add_child(viewport)
	screen.viewport = viewport  # 贴图由 SubView3D 自己绑定
	_setup_background()

	# 屏幕自发光(不吃光照), 全屏按贴图原样显示
	var mat := screen.get_surface_override_material(0) as StandardMaterial3D
	mat.albedo_color = Color.WHITE
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = false


func _setup_background() -> void:
	if own_world:
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = background
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.6, 0.62, 0.7)
		env.ambient_light_energy = 0.8
		var world_env := WorldEnvironment.new()
		world_env.environment = env
		viewport.add_child(world_env)
		return
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = background
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.z_index = -1
	viewport.add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
