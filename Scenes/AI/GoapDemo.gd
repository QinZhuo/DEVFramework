extends Control

## GOAP 演示 · 2D 生态箱
##
## 一个由 GOAP 驱动的简单生态系统：
##   - 兔（食草动物）: 饥饿时寻找并吃掉草；感知到狐狸时优先逃跑（高优先级目标覆盖）
##   - 狐（捕食者）  : 饥饿时追踪并捕食兔子（兔子被捕食后在别处重生）
##   - 草（资源）    : 被进食后消失，延迟后在随机位置重生
##
## 所有目标 / 行动均来自 Assets/Def/Goap/Ecosystem/ 配置资源（配置驱动），
## 本脚本只负责生成生态、绑定日志与统计。

@export var grass_count: int = 26
@export var rabbit_count: int = 6
@export var fox_count: int = 2
@export var hunger_interval: float = 5.0

@onready var world: Node2D = %World
@onready var stats_label: Label = %StatsLabel
@onready var log_box: RichTextLabel = %LogBox
@onready var pause_button: Button = %PauseButton
@onready var speed_button: Button = %SpeedButton

var _agents: Array[GoapAgent] = []
var _hunger_timer := 0.0
var _paused := false


func _ready() -> void:
	randomize()
	_spawn_world()
	_log("生态箱启动：%d 草 / %d 兔 / %d 狐" % [grass_count, rabbit_count, fox_count])


func _process(delta: float) -> void:
	_hunger_timer += delta
	if _hunger_timer >= hunger_interval:
		_hunger_timer = 0.0
		_trigger_hunger()
	_update_stats()


## —— 世界生成 ——

func _spawn_world() -> void:
	for i in grass_count:
		var grass := Grass.new()
		grass.position = EcosystemWorld.rand_pos()
		world.add_child(grass)
	for i in rabbit_count:
		var rabbit := RabbitAgent.new()
		world.add_child(rabbit)
		rabbit.set_state("hungry", randf() < 0.6)
		_bind_agent(rabbit)
	for i in fox_count:
		var fox := FoxAgent.new()
		world.add_child(fox)
		fox.set_state("hungry", true)
		_bind_agent(fox)


func _bind_agent(agent: GoapAgent) -> void:
	_agents.append(agent)
	agent.plan_found.connect(func(goal: GoapGoal, _plan: Array):
		_log("◎ %s 目标：%s" % [agent.name, goal.def.name])
	)
	agent.action_started.connect(func(action: GoapAction):
		_log("▶ %s 执行：%s" % [agent.name, action.def.name])
	)


## —— 饥饿驱动 ——

## 每隔一段时间随机让一只未进食的兔 / 狐变饿，驱动 GOAP 持续规划
func _trigger_hunger() -> void:
	var rabbits: Array[RabbitAgent] = []
	for r in get_tree().get_nodes_in_group(&"rabbit"):
		if r.body.visible and not r.get_state("hungry", false):
			rabbits.append(r)
	if not rabbits.is_empty():
		rabbits.pick_random().make_hungry()

	var foxes: Array[FoxAgent] = []
	for f in get_tree().get_nodes_in_group(&"fox"):
		if not f.get_state("hungry", false):
			foxes.append(f)
	if not foxes.is_empty():
		foxes.pick_random().make_hungry()


## —— 统计 ——

func _update_stats() -> void:
	var grass_n := 0
	for g in get_tree().get_nodes_in_group(&"grass"):
		if g.is_available():
			grass_n += 1
	var rabbit_n := 0
	for r in get_tree().get_nodes_in_group(&"rabbit"):
		if r.body.visible:
			rabbit_n += 1
	var fox_n := get_tree().get_nodes_in_group(&"fox").size()
	stats_label.text = "草 x%d ｜ 兔 x%d ｜ 狐 x%d" % [grass_n, rabbit_n, fox_n]


## —— 按钮 ——

func _on_pause_pressed() -> void:
	_paused = not _paused
	pause_button.text = "继续" if _paused else "暂停"
	for a in _agents:
		a.paused = _paused
	_log("模拟 %s" % ("已暂停" if _paused else "已恢复"))


func _on_speed_pressed() -> void:
	Engine.time_scale = 2.0 if Engine.time_scale < 2.0 else 1.0
	speed_button.text = "正常 x1" if Engine.time_scale == 2.0 else "加速 x2"
	_log("模拟速度 x%d" % int(Engine.time_scale))


func _on_reset_pressed() -> void:
	_paused = false
	Engine.time_scale = 1.0
	pause_button.text = "暂停"
	speed_button.text = "加速 x2"
	for a in _agents:
		a.queue_free()
	_agents.clear()
	for g in get_tree().get_nodes_in_group(&"grass"):
		g.queue_free()
	_spawn_world()
	_log("世界已重置")


## —— 日志 ——

func _log(msg: String) -> void:
	log_box.append_text("%s\n" % msg)
	log_box.scroll_to_line(log_box.get_line_count())
