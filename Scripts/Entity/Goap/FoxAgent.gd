class_name FoxAgent extends GoapAgent
## 生态箱演示：捕食者（狐）。
##
## 世界状态: hungry / has_prey / near_prey
## 目标: 狩猎(20)
## 目标与行动来自 Assets/Def/Goap/Ecosystem/ 配置资源（配置驱动）。
## 展示: 感知猎物、异步追踪移动、捕食重置状态。
##
## 注: GoapAgent 基类为 Node（纯大脑），位置/视觉由子节点 body(BodyVisual) 承载。

const BODY_VISUAL := preload("res://Scripts/Entity/Goap/BodyVisual.gd")
const HUNT_GOAL := preload("res://Assets/Def/Goap/Ecosystem/狩猎.tres")
const FIND_PREY_ACTION := preload("res://Assets/Def/Goap/Ecosystem/寻找猎物.tres")
const CHASE_PREY_ACTION := preload("res://Assets/Def/Goap/Ecosystem/追踪猎物.tres")
const HUNT_ACTION := preload("res://Assets/Def/Goap/Ecosystem/捕食.tres")

@export var move_speed: float = 130.0

var body: BodyVisual
var _prey_target: RabbitAgent = null
var _move_target := Vector2.ZERO
var _moving := false
var _move_done: Callable = Callable()
var _status_label: Label


func _ready_goap() -> void:
	goals = [HUNT_GOAL]
	actions = [FIND_PREY_ACTION, CHASE_PREY_ACTION, HUNT_ACTION]
	replan_interval = 0.6
	debug_enabled = true

	set_state("hungry", false)
	set_state("has_prey", false)
	set_state("near_prey", false)

	add_to_group(&"fox")
	_setup_body()
	_setup_status_label()


func _process(delta: float) -> void:
	super._process(delta)
	_update_movement(delta)
	_update_awareness()
	if not has_plan() and _status_label:
		_status_label.text = "游荡中"


func _setup_body() -> void:
	body = BodyVisual.new()
	body.radius = 13.0
	body.body_color = Color(0.9, 0.5, 0.2)
	body.position = EcosystemWorld.rand_pos()
	add_child(body)


## —— 感知 ——

func _update_awareness() -> void:
	_prey_target = _nearest_rabbit()


func _nearest_rabbit() -> RabbitAgent:
	var best: RabbitAgent = null
	var best_dist := INF
	for r in get_tree().get_nodes_in_group(&"rabbit"):
		var rabbit := r as RabbitAgent
		if rabbit == null or not rabbit.body.visible:
			continue
		var d := body.position.distance_to(rabbit.body.position)
		if d < best_dist:
			best_dist = d
			best = rabbit
	return best


## —— 行动：狩猎链 ——

func perform_find_prey(_action: GoapAction) -> bool:
	_prey_target = _nearest_rabbit()
	if _prey_target == null:
		_status("搜寻猎物")
		return false
	_status("发现猎物！")
	return true


func perform_chase_prey(_action: GoapAction) -> Variant:
	if _prey_target == null or not _prey_target.body.visible:
		return false
	_status("追捕中")
	_move_to(_prey_target.body.position, func() -> void:
		if _prey_target != null and _prey_target.body.visible \
				and body.position.distance_to(_prey_target.body.position) < 16.0:
			notify_action_finished(true)
		else:
			notify_action_finished(false)
	)
	return null


func perform_hunt(_action: GoapAction) -> bool:
	if _prey_target == null or not _prey_target.body.visible:
		return false
	_status("捕食！")
	_prey_target.being_eaten()
	return true


## —— 移动 ——

func _move_to(target: Vector2, on_done: Callable) -> void:
	_move_target = target
	_move_done = on_done
	_moving = true


func _update_movement(delta: float) -> void:
	if not _moving:
		return
	body.position = body.position.move_toward(_move_target, move_speed * delta)
	if body.position.distance_to(_move_target) < 3.0:
		body.position = _move_target
		_moving = false
		var cb := _move_done
		_move_done = Callable()
		cb.call()


## —— 状态提示 ——

func make_hungry() -> void:
	set_state("hungry", true)


func _setup_status_label() -> void:
	if _status_label != null:
		return
	_status_label = Label.new()
	_status_label.z_index = 10
	_status_label.position = Vector2(-45.0, -36.0)
	_status_label.size = Vector2(90.0, 18.0)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.95))
	body.add_child(_status_label)


func _status(text: String) -> void:
	if _status_label:
		_status_label.text = text
