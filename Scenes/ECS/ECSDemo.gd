extends Control

## ECS 演示 —— 四种实现方式对比: 左下角按钮切换, 表格显示各实现耗时/帧率。
## 四种实现各自独立脚本、独立文件夹(便于对照学习):
##   res://Scripts/Entity/ECS/Demo/impl_node/      普通 Node 实现(纯 OOP, 不用 ECS)
##   res://Scripts/Entity/ECS/Demo/impl_query/     ECS 查询链实现(声明式 batch: 组件 + 系统 + for_each)
##   res://Scripts/Entity/ECS/Demo/impl_callback/  ECS 查询链回调实现(同一数据布局, 逻辑用手写 .with().process() 回调)
##   res://Scripts/Entity/ECS/Demo/impl_entity/    Entity 节点写法(@export 即 schema + 系统批量)
##
## 小球逻辑(四种实现完全一致): 随机移动(边界回弹) + hp 周期 0→100→0 增减 + 大小随 hp。
## 四种实现都用真实节点显示。切换时销毁上一个实现、只保留当前。
## 额外能力:
##   · 创建耗时: 每次切换/启动记录"创建世界"的耗时(建实体/节点/数据), 表格对比
##   · 渲染开关: 屏蔽渲染相关逻辑(位置/显示更新), 只做数值运算, 对比渲染同步的开销
## 本脚本只做调度: 实例化/删除各实现的场景, 测量耗时, 渲染表格。

const IMPL_NAMES := ["普通Node实现", "ECS查询链实现", "ECS回调实现", "Entity节点写法"]
# 每个实现一个场景(放在对应脚本文件夹下), 切模式 = 实例化/删除对应场景
const IMPL_SCENES := [
	"res://Scripts/Entity/ECS/Demo/impl_node/impl_node.tscn",
	"res://Scripts/Entity/ECS/Demo/impl_query/impl_query.tscn",
	"res://Scripts/Entity/ECS/Demo/impl_callback/impl_callback.tscn",
	"res://Scripts/Entity/ECS/Demo/impl_entity/impl_entity.tscn",
]
const INIT_SEED := 20260808

@export var ball_count: int = 10000
@export var max_ball_size: float = 8.0      # 100 hp 时的小球尺寸(0 hp 消失)

@onready var stats_label: Label = %StatsLabel
@onready var switch_button: Button = %SwitchButton
@onready var render_button: Button = %RenderButton

var _impl = null                            # 当前实现(DemoImpl 或场景化世界节点), 切模式时重建
var _current := 1                            # 0=普通Node, 1=ECS查询链(默认), 2=ECS回调, 3=Entity节点写法
var _setup_ms := 0.0                         # 当前实现"创建世界"耗时(ms)
var _render_on := true                       # 渲染开关

# 各实现已测结果: 实现名 -> {ms, fps, setup_ms}(切换时写入)
var _results := {}

# 当前实现滚动平均(最近 WINDOW 帧)
var _ms_window: Array = []
const WINDOW := 60
var _frame := 0


func _ready() -> void:
	switch_button.pressed.connect(_on_switch_pressed)
	render_button.pressed.connect(_on_render_toggled)
	_spawn(_current)
	_refresh_ui()


func _spawn(idx: int) -> void:
	# 每个实现 = 一个场景(世界/系统/同步规则都在场景 Inspector 配置), 实例化即完成初始化
	var t0 := Time.get_ticks_usec()
	var scn: PackedScene = load(IMPL_SCENES[idx])
	var node := scn.instantiate()
	%WorldRoot.add_child(node)
	_impl = node
	_apply_render(_impl)
	_setup_ms = (Time.get_ticks_usec() - t0) / 1000.0


## 渲染开关应用到当前实现(场景化世界走 set_render_enabled 方法, 代码实现走属性)。
func _apply_render(impl) -> void:
	if impl.has_method("set_render_enabled"):
		impl.set_render_enabled(_render_on)
	elif "render_enabled" in impl:
		impl.render_enabled = _render_on


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
	_results[IMPL_NAMES[_current]] = {
		"ms": _avg_ms(), "fps": 1000.0 / maxf(_avg_ms(), 0.001), "setup_ms": _setup_ms,
	}
	if _impl.has_method("teardown"):
		_impl.teardown()
	else:
		_impl.queue_free()   # 场景化实现: 删除场景
	_current = (_current + 1) % IMPL_NAMES.size()
	_spawn(_current)
	_ms_window.clear()
	_refresh_ui()


func _on_render_toggled() -> void:
	# 切换渲染开关: 屏蔽位置/显示同步, 只保留数值运算(对比渲染开销)
	_render_on = not _render_on
	if _impl:
		_apply_render(_impl)
	_refresh_ui()


## 以表格形式展示各实现的创建耗时/平均耗时/帧率(已测的固定, 当前行实时刷新)。
func _refresh_ui() -> void:
	var text := "ECS 小球对比测试 ｜ 每路 %d 个小球(真实节点显示)\n" % ball_count
	text += "生命值 0→100 周期增减, 大小随 hp\n\n"
	text += "实现                创建      平均耗时   平均帧率\n"
	text += "──────────────────────────────────────────\n"
	for i in IMPL_NAMES.size():
		var name: String = IMPL_NAMES[i]
		var cur_ms := _avg_ms() if i == _current else 0.0
		var cur_setup := _setup_ms if i == _current else 0.0
		var mark := "▶" if i == _current else " "
		if _results.has(name):
			var r: Dictionary = _results[name]
			text += "%s %-14s  %6.1fms  %8.3fms  %5d FPS\n" % [mark, name, r.setup_ms, r.ms, int(r.fps)]
		elif i == _current:
			text += "%s %-14s  %6.1fms  %8.3fms  %5d FPS  (测中)\n" % [mark, name, cur_setup, cur_ms, int(1000.0 / maxf(cur_ms, 0.001))]
		else:
			text += "%s %-14s      —        —        —\n" % [mark, name]
	text += "\n渲染: %s  (点击右下按钮切换, 屏蔽位置/显示同步对比纯数值开销)" % ("开 🎨" if _render_on else "关 🚫")
	text += "\n🖱 点击下方按钮切换实现"
	stats_label.text = text
