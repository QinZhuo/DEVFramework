extends Control

## ECS 演示 —— 大量随机移动小球 + 生命值周期增减, 对比两种实现:
##   ◀ 普通 Node 实现(常规 OOP): 每个小球一个 Node2D, 逻辑写在 _process
##   ▶ ECS 查询链实现(普通程序员用框架): 组件存数据, 系统用 for_each 查询链 + process 回调
##
## 小球逻辑(两种实现完全一致): 随机移动(边界回弹) + hp 周期 0→100→0 增减 + 大小随 hp。
## UI 显示当前实现的滚动平均耗时/帧率, 以及上一个实现的平均。

const IMPL_NAMES := ["普通Node实现", "ECS查询链实现"]
const INIT_SEED := 20260808

@export var ball_count: int = 10000
@export var max_ball_size: float = 8.0      # 100 hp 时的小球尺寸(0 hp 消失)

@onready var cloud: ECSPointCloud = %Cloud
@onready var stats_label: Label = %StatsLabel
@onready var switch_button: Button = %SwitchButton

var _world: ECSWorld = null                 # ECS 实现(查询链)
var _plain_nodes: Array[DemoBallNode] = []
var _current := 1                            # 0=Node, 1=ECS(默认展示框架)

# 各实现已测结果: 实现名 -> {ms, fps}(切换时写入)
var _results := {}

# 当前实现滚动平均(最近 WINDOW 帧)
var _ms_window: Array = []
const WINDOW := 60
var _frame := 0


func _ready() -> void:
	switch_button.pressed.connect(_on_switch_pressed)
	_build_ecs()
	_build_plain()
	_apply_impl()
	_refresh_ui()


## 建立 ECS 实现(查询链): 组件 ECSDemoBall + DemoScriptSystem(process 回调)。
func _build_ecs() -> void:
	_world = ECSWorld.new(false)
	_world.register_component(ECSDemoBall)
	_world.register_system(DemoScriptSystem.new())
	var rng := RandomNumberGenerator.new()
	rng.seed = INIT_SEED
	for _i in ball_count:
		var e := _world.create_entity()
		_world.add_component(e, ECSDemoBall)
		_world.set_field(e, ECSDemoBall, &"x", rng.randf_range(20.0, 1140.0))
		_world.set_field(e, ECSDemoBall, &"y", rng.randf_range(20.0, 700.0))
		var ang := rng.randf() * TAU
		var spd := rng.randf_range(20.0, 60.0)
		_world.set_field(e, ECSDemoBall, &"vx", cos(ang) * spd)
		_world.set_field(e, ECSDemoBall, &"vy", sin(ang) * spd)
		_world.set_field(e, ECSDemoBall, &"hp", rng.randf_range(0.0, 100.0))


## 建立普通 Node 实现(同种子同布局)。
func _build_plain() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = INIT_SEED
	for _i in ball_count:
		var n := DemoBallNode.new()
		n.position = Vector2(rng.randf_range(20.0, 1140.0), rng.randf_range(20.0, 700.0))
		var ang := rng.randf() * TAU
		var spd := rng.randf_range(20.0, 60.0)
		n.vx = cos(ang) * spd
		n.vy = sin(ang) * spd
		n.hp = rng.randf_range(0.0, 100.0)
		%WorldRoot.add_child(n)
		n.set_process(false)   # 由主循环手动驱动, 便于测耗时
		_plain_nodes.append(n)


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if _current == 1:
		_world.tick(delta)
	else:
		for n in _plain_nodes:
			n._process(delta)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_ms_window.append(ms)
	if _ms_window.size() > WINDOW:
		_ms_window.pop_front()
	_frame += 1
	if _frame % 5 == 0:
		_refresh_cloud()
		_refresh_ui()


## 从当前实现拉取小球位置/尺寸, 交给点阵渲染。
func _refresh_cloud() -> void:
	var pts := PackedVector2Array()
	var sizes := PackedFloat32Array()
	var scale := max_ball_size / 100.0
	if _current == 1:
		var xcol: PackedFloat32Array = _world.get_column(ECSDemoBall, &"x")
		var ycol: PackedFloat32Array = _world.get_column(ECSDemoBall, &"y")
		var scol: PackedFloat32Array = _world.get_column(ECSDemoBall, &"size")
		var n := xcol.size()
		pts.resize(n)
		sizes.resize(n)
		for i in n:
			pts[i] = Vector2(xcol[i], ycol[i])
			sizes[i] = scol[i] * scale   # size=hp → 0 消失, 100 最大
	else:
		for b in _plain_nodes:
			pts.append(b.position)
			sizes.append(b.size * scale)
	cloud.set_points(pts)
	cloud.set_sizes(sizes)


func _avg_ms() -> float:
	if _ms_window.is_empty():
		return 0.0
	var s := 0.0
	for m in _ms_window:
		s += m
	return s / _ms_window.size()


func _on_switch_pressed() -> void:
	# 把当前实现结果写入表格
	_results[IMPL_NAMES[_current]] = {"ms": _avg_ms(), "fps": 1000.0 / maxf(_avg_ms(), 0.001)}
	_current = (_current + 1) % IMPL_NAMES.size()
	_ms_window.clear()
	_apply_impl()
	_refresh_ui()


## 应用当前实现(控制普通 Node 逻辑启停) + 立即刷新画面。
func _apply_impl() -> void:
	for n in _plain_nodes:
		n.logic_enabled = (_current == 0)
	_refresh_cloud()


## 以表格形式展示各实现的平均耗时与帧率(已测的固定, 当前行实时刷新)。
func _refresh_ui() -> void:
	var text := "ECS 小球对比测试 ｜ 每路 %d 个小球\n" % ball_count
	text += "生命值 0→100 周期增减, 大小随 hp\n\n"
	text += "实现            平均耗时   平均帧率\n"
	text += "─────────────────────────────\n"
	for i in IMPL_NAMES.size():
		var name: String = IMPL_NAMES[i]
		var cur_ms := _avg_ms() if i == _current else 0.0
		if _results.has(name):
			var r: Dictionary = _results[name]
			text += "%s %-10s  %6.3f ms  %5d FPS\n" % ["▶" if i == _current else " ", name, r.ms, int(r.fps)]
		elif i == _current:
			text += "%s %-10s  %6.3f ms  %5d FPS  (测中)\n" % ["▶", name, cur_ms, int(1000.0 / maxf(cur_ms, 0.001))]
		else:
			text += "%s %-10s       —        —\n" % [" ", name]
	text += "\n🖱 点击下方按钮切换实现"
	stats_label.text = text
