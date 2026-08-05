class_name RabbitAgent extends GoapAgent
## 生态箱演示：食草动物（兔）。
##
## 世界状态: hungry / has_food / near_food / predator_near
## 目标(优先级): 逃离危险(30) > 填饱肚子(20)
## 目标与行动全部来自 Assets/Def/Goap/Ecosystem/ 配置资源（配置驱动）。
## 展示: 多目标优先级、感知触发状态变化、异步移动行动、被捕食后重生。
##
## 注: GoapAgent 基类为 Node（纯大脑），位置/视觉由子节点 body(BodyVisual) 承载。

const BODY_VISUAL := preload("res://Scripts/Entity/Goap/BodyVisual.gd")
const FLEE_GOAL := preload("res://Assets/Def/Goap/Ecosystem/逃离危险.tres")
const EAT_GOAL := preload("res://Assets/Def/Goap/Ecosystem/填饱肚子.tres")
const FIND_FOOD_ACTION := preload("res://Assets/Def/Goap/Ecosystem/寻找食物.tres")
const WALK_FOOD_ACTION := preload("res://Assets/Def/Goap/Ecosystem/走向食物.tres")
const EAT_FOOD_ACTION := preload("res://Assets/Def/Goap/Ecosystem/进食.tres")
const FLEE_ACTION := preload("res://Assets/Def/Goap/Ecosystem/逃跑.tres")

@export var move_speed: float = 90.0
@export_range(80.0, 400.0) var danger_radius: float = 170.0

var body: BodyVisual
var _nearest_fox: FoxAgent = null
var _move_target := Vector2.ZERO
var _moving := false
var _move_done: Callable = Callable()
var _status_label: Label


func _ready_goap() -> void:
	goals = [FLEE_GOAL, EAT_GOAL]
	actions = [FIND_FOOD_ACTION, WALK_FOOD_ACTION, EAT_FOOD_ACTION, FLEE_ACTION]
	replan_interval = 0.6
	debug_enabled = true

	set_state("hungry", false)
	set_state("has_food", false)
	set_state("near_food", false)
	set_state("predator_near", false)

	add_to_group(&"rabbit")
	add_to_group(&"prey")
	_setup_body()
	_setup_status_label()


func _process(delta: float) -> void:
	super._process(delta)
	_update_movement(delta)
	_update_awareness()
	if not has_plan() and _status_label:
		_status_label.text = "休息中"


func _setup_body() -> void:
	body = BodyVisual.new()
	body.radius = 11.0
	body.body_color = Color(0.93, 0.86, 0.66)
	body.position = EcosystemWorld.rand_pos()
	add_child(body)


## —— 感知 ——

## 每帧感知最近的狐狸；距离 < danger_radius 时标记危险（触发高优先级逃跑目标）
func _update_awareness() -> void:
	_nearest_fox = null
	var best_dist := INF
	for f in get_tree().get_nodes_in_group(&"fox"):
		var fox := f as FoxAgent
		if fox == null or not fox.body.visible:
			continue
		var d: float = body.position.distance_to(fox.body.position)
		if d < best_dist:
			best_dist = d
			_nearest_fox = fox
	var danger := _nearest_fox != null and best_dist < danger_radius
	if danger != get_state("predator_near", false):
		set_state("predator_near", danger)


## —— 行动：觅食链 ——
## 目标草绑定到 action.target（由行动生命周期 begin/end 自动管理，无需手写成员清理）。
## 草可能被其他兔子抢先吃掉导致 target 失效；行动返回失败后框架进入失败冷却，
## 并通过 begin(可重新找草)→end(清 target)→冷却→重规划 的过程自然收敛，不会死循环。

func begin_find_food(action: GoapAction) -> void:
	action.target = _nearest_grass()


func perform_find_food(action: GoapAction) -> bool:
	var grass := action.target as Grass
	if grass == null:
		_status("觅食：附近没有草")
		set_state("has_food", false)
		set_state("near_food", false)
		return false
	_status("觅食：发现食物")
	return true


func begin_walk_to_food(action: GoapAction) -> void:
	var grass := action.target as Grass
	if grass == null or not grass.is_available():
		action.target = _nearest_grass()


func perform_walk_to_food(action: GoapAction) -> Variant:
	var grass := action.target as Grass
	if grass == null or not grass.is_available():
		set_state("has_food", false)
		set_state("near_food", false)
		return false
	_status("前往食物")
	_move_to(grass.position, func() -> void:
		var g := action.target as Grass
		if g != null and g.is_available():
			notify_action_finished(true)
		else:
			# 途中草被吃: 清空状态让 replan 重新寻找食物, 而非拿着失效目标空转
			set_state("has_food", false)
			set_state("near_food", false)
			notify_action_finished(false)
	)
	return null


func begin_eat_food(action: GoapAction) -> void:
	# 进食是独立规划的新行动, target 需重新绑定(兔子已站在食物旁, 最近的草即目标)
	if action.target == null:
		action.target = _nearest_grass()


func perform_eat_food(action: GoapAction) -> bool:
	var grass := action.target as Grass
	if grass == null or not grass.is_available():
		set_state("has_food", false)
		set_state("near_food", false)
		return false
	_status("进食中")
	grass.eaten()
	return true


func _nearest_grass() -> Grass:
	var best: Grass = null
	var best_dist := INF
	for g in get_tree().get_nodes_in_group(&"grass"):
		var grass := g as Grass
		if grass == null or not grass.is_available():
			continue
		var d := body.position.distance_to(grass.position)
		if d < best_dist:
			best_dist = d
			best = grass
	return best


## —— 行动：逃跑（异步移动） ——
## 注意: 逃跑必须"持续远离直到脱离狐狸感知圈", 否则兔子到达单次固定距离的目标后
## 狐狸仍在 danger_radius 内, predator_near 又被置 true -> 同帧 replan -> 再次逃跑,
## 形成每帧"逃跑完成->重规划->逃跑"的死循环(卡死)。

func perform_flee(_action: GoapAction) -> Variant:
	_status("逃跑！")
	_flee_step()
	return null


## 向远离狐狸的方向跑一步; 到达后若狐狸仍在感知圈内, 继续向更远处跑, 直到脱离
func _flee_step() -> void:
	var away := Vector2.RIGHT
	if _nearest_fox != null:
		away = body.position - _nearest_fox.body.position
	if away.length_squared() < 1.0:
		away = Vector2.RIGHT.rotated(randf() * TAU)
	var dist_to_fox := body.position.distance_to(_nearest_fox.body.position) if _nearest_fox != null else INF
	# 目标距离: 至少 260, 若狐狸逼近则需逃出感知圈外再留 60 余量
	var step := maxf(260.0, danger_radius - dist_to_fox + 60.0)
	var target := EcosystemWorld.clamp_pos(body.position + away.normalized() * step)
	_move_to(target, func() -> void:
		if _fox_still_after_me():
			_flee_step()
		else:
			notify_action_finished(true)
	)


func _fox_still_after_me() -> bool:
	var fox := _nearest_fox
	if fox == null or not is_instance_valid(fox):
		return false
	if not fox.body.visible:
		return false
	return body.position.distance_to(fox.body.position) < danger_radius


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


## 中断移动：取消进行中的移动与等待中的完成回调
func _interrupt_move() -> void:
	_moving = false
	_move_done = Callable()


## —— 被捕食 / 重生 ——

func being_eaten() -> void:
	if not body.visible:
		return
	body.visible = false
	paused = true
	_interrupt_move()
	reset_plan()
	_status_label.visible = false
	get_tree().create_timer(3.5).timeout.connect(_respawn)


func _respawn() -> void:
	if not is_inside_tree():
		return
	body.position = EcosystemWorld.rand_pos()
	body.visible = true
	paused = false
	_interrupt_move()
	_status_label.visible = true
	_status("重获新生")
	reset_plan()
	world_state.reset({})
	set_state("hungry", randf() < 0.7)
	set_state("has_food", false)
	set_state("near_food", false)
	set_state("predator_near", false)
	mark_dirty()


## —— 状态提示 ——

func make_hungry() -> void:
	if not body.visible:
		return
	set_state("hungry", true)


func _setup_status_label() -> void:
	if _status_label != null:
		return
	_status_label = Label.new()
	_status_label.z_index = 10
	_status_label.position = Vector2(-45.0, -32.0)
	_status_label.size = Vector2(90.0, 18.0)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.95))
	body.add_child(_status_label)


func _status(text: String) -> void:
	if _status_label:
		_status_label.text = text
