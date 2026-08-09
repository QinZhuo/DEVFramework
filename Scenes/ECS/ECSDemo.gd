extends Control

## ECS 演示 —— 三种实现方式对比: 左下角按钮切换, 表格显示各实现耗时/帧率。
## 三种实现各自独立脚本、独立文件夹(便于对照学习):
##   res://Scripts/Entity/ECS/Demo/impl_node/    普通 Node 实现(纯 OOP, 不用 ECS)
##   res://Scripts/Entity/ECS/Demo/impl_query/   ECS 查询链实现(组件 + 系统 + for_each)
##   res://Scripts/Entity/ECS/Demo/impl_entity/  Entity 节点写法(传统 OOP 写法自动接 ECS)
##
## 小球逻辑(三种实现完全一致): 随机移动(边界回弹) + hp 周期 0→100→0 增减 + 大小随 hp。
## 三种实现都用**真实节点显示**。切换时**销毁上一个实现、只保留当前**, 减少互相影响。
## 本脚本只做调度: 创建/销毁当前 DemoImpl, 测量耗时, 渲染表格。

const IMPL_NAMES := ["普通Node实现", "ECS查询链实现", "Entity节点写法"]
const INIT_SEED := 20260808

@export var ball_count: int = 10000
@export var max_ball_size: float = 8.0      # 100 hp 时的小球尺寸(0 hp 消失)

@onready var stats_label: Label = %StatsLabel
@onready var switch_button: Button = %SwitchButton

var _impl: DemoImpl = null
var _current := 1                            # 0=普通Node, 1=ECS查询链(默认), 2=Entity节点写法

# 各实现已测结果: 实现名 -> {ms, fps}(切换时写入)
var _results := {}

# 当前实现滚动平均(最近 WINDOW 帧)
var _ms_window: Array = []
const WINDOW := 60
var _frame := 0


func _ready() -> void:
	switch_button.pressed.connect(_on_switch_pressed)
	_spawn(_current)
	_refresh_ui()


func _spawn(idx: int) -> void:
	var cls: Script = null
	match idx:
		0:
			cls = DemoNodeImpl
		1:
			cls = DemoQueryImpl
		_:
			cls = DemoEntityImpl
	_impl = cls.new()
	_impl.setup(ball_count, INIT_SEED, %WorldRoot)


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_impl.tick(delta)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_ms_window.append(ms)
	if _ms_window.size() > WINDOW:
		_ms_window.pop_front()
	_frame += 1
	if _frame % 5 == 0:
		_refresh_ui()


func _avg_ms() -> float:
	if _ms_window.is_empty():
		return 0.0
	var s := 0.0
	for m in _ms_window:
		s += m
	return s / _ms_window.size()


func _on_switch_pressed() -> void:
	# 把当前实现结果写入表格, 然后销毁它、重建下一个实现(只保留当前, 减少互相影响)
	_results[_impl.impl_name] = {"ms": _avg_ms(), "fps": 1000.0 / maxf(_avg_ms(), 0.001)}
	_impl.teardown()
	_current = (_current + 1) % IMPL_NAMES.size()
	_spawn(_current)
	_ms_window.clear()
	_refresh_ui()


## 以表格形式展示各实现的平均耗时与帧率(已测的固定, 当前行实时刷新)。
func _refresh_ui() -> void:
	var text := "ECS 小球对比测试 ｜ 每路 %d 个小球(真实节点显示)\n" % ball_count
	text += "生命值 0→100 周期增减, 大小随 hp\n\n"
	text += "实现                平均耗时   平均帧率\n"
	text += "──────────────────────────────\n"
	for i in IMPL_NAMES.size():
		var name: String = IMPL_NAMES[i]
		var cur_ms := _avg_ms() if i == _current else 0.0
		if _results.has(name):
			var r: Dictionary = _results[name]
			text += "%s %-16s  %7.3f ms  %5d FPS\n" % ["▶" if i == _current else " ", name, r.ms, int(r.fps)]
		elif i == _current:
			text += "%s %-16s  %7.3f ms  %5d FPS  (测中)\n" % ["▶", name, cur_ms, int(1000.0 / maxf(cur_ms, 0.001))]
		else:
			text += "%s %-16s       —        —\n" % [" ", name]
	text += "\n🖱 点击下方按钮切换实现"
	stats_label.text = text
