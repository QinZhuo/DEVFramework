extends Node

## ECS 演示台 —— **唯一入口**，把各个 ECS 演示作为"模式"挂进来。
##
## 为什么合并: 之前是 5~6 个独立场景(Stress/Spatial/Rollback/MultiMesh/Barrage/NodeDemo),
## 每个都要单独打开、且不知道"这个 demo 想说明什么"。现在一个场景 + F1~F8 切换 + 常驻说明。
##
## 操作: F1~F8 直接选模式, Tab 下一个, F2 之类不会与子 demo 的 1/2/W/S/R/P 冲突。
## 子 demo 仍以独立场景存在(它们是"模式模块"), 但不再作为入口文档/入口点。

const MODES := [
	{
		"name": "压力测试",
		"scene": "res://Scenes/ECSDemo/ECSStressDemo.tscn",
		"desc": "上万实体的批量推进/写列, 看每帧耗时与 CPU 占用",
	},
	{
		"name": "空间索引",
		"scene": "res://Scenes/ECSDemo/ECSSpatialDemo.tscn",
		"desc": "半径查询 vs 全表扫; 圆圈=查询中心(鼠标), 红点=命中",
	},
	{
		"name": "回滚",
		"scene": "res://Scenes/ECSDemo/ECSRollbackDemo.tscn",
		"desc": "快照 + 差分回滚, 验证确定性与存档体积",
	},
	{
		"name": "MultiMesh 渲染",
		"scene": "res://Scenes/ECSDemo/ECSMultiMeshDemo.tscn",
		"desc": "ECS+MultiMesh vs 每实体一个 Node3D; 看渲染对象数与 FPS",
	},
	{
		"name": "3D 弹幕 + 飘字",
		"scene": "res://Scenes/ECSDemo/ECSBarrage3DDemo.tscn",
		"desc": "Spawner → Projectile → MultiMesh + PopupText 四条链路同屏",
	},
	{
		"name": "节点同步",
		"scene": "res://Scenes/ECS/ECSNodeDemo.tscn",
		"desc": "实体 ↔ Node3D 显式桥(需要碰撞/拾取/节点信号时用这条路径)",
	},
	{
		"name": "查询 DSL",
		"scene": "res://Scenes/ECS/impl_query.tscn",
		"desc": "ECSQuery 的条件/组合/聚合写法",
	},
]

var _idx := -1
var _current: Node = null
var _label: Label
var _panel: ColorRect


func _ready() -> void:
	_build_ui()
	_switch(0)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10           # 压在各子 demo 的 HUD 之上
	add_child(layer)

	_panel = ColorRect.new()
	_panel.color = Color(0.05, 0.06, 0.08, 0.78)
	layer.add_child(_panel)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 14)
	layer.add_child(_label)


func _switch(i: int) -> void:
	if i < 0 or i >= MODES.size():
		return
	if _current != null and is_instance_valid(_current):
		remove_child(_current)
		_current.queue_free()
		_current = null
	var mode: Dictionary = MODES[i]
	var packed: PackedScene = load(String(mode["scene"]))
	if packed == null:
		_label.text = "模式 %d 加载失败: %s" % [i + 1, mode["scene"]]
		return
	_current = packed.instantiate()
	add_child(_current)
	_idx = i
	_refresh_hud()


func _refresh_hud() -> void:
	var m: Dictionary = MODES[_idx]
	var lines := PackedStringArray()
	lines.append("ECS 演示台   [F1~F%d] 直接选   [Tab] 下一个" % MODES.size())
	lines.append("当前 %d. %s —— %s" % [_idx + 1, String(m["name"]), String(m["desc"])])
	lines.append("")
	# 模式列表用**两行紧凑排**(逐行排会随模式数增长把面板顶出屏幕底边)
	var names := PackedStringArray()
	for i in MODES.size():
		names.append("%sF%d %s" % ["▶" if i == _idx else "", i + 1, String(MODES[i]["name"])])
	var half := int(ceil(float(names.size()) / 2.0))
	lines.append("   ".join(names.slice(0, half)))
	lines.append("   ".join(names.slice(half)))
	_label.text = "\n".join(lines)

	# 面板高度按**行数**算并贴底(写死高度必然被模式数量/字体变化截断)
	const LINE_H := 20.0
	var h := 16.0 + float(lines.size()) * LINE_H
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_panel.size = Vector2(560, h)
	_panel.position = Vector2(12, vp.y - h - 10)
	_label.position = _panel.position + Vector2(10, 6)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var kc := (event as InputEventKey).keycode
	if kc == KEY_TAB:
		_switch((_idx + 1) % MODES.size())
		get_viewport().set_input_as_handled()
		return
	if kc >= KEY_F1 and kc <= KEY_F12:
		_switch(kc - KEY_F1)
		get_viewport().set_input_as_handled()
