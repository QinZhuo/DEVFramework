extends CharacterBody3D
## 3D 三态 AI NPC — 用 Godot 自带 NavigationAgent3D 在导航网格上自动寻路移动
##
## 状态机：PATROL（随机巡逻）→ CHASE（目标进入视野，追逐）→ FLEE（目标过近，逃跑）
## 演示 PCG 导航桥接 + 引擎原生寻路的连续移动 + 简单行为切换。

enum AIState { PATROL, CHASE, FLEE }

@export var move_speed := 3.0
@export var agent_radius := 0.4
@export var patrol_center := Vector3.ZERO
@export var patrol_radius := 8.0
## 视野半径：目标进入此范围 → 追逐
@export var chase_range := 10.0
## 逃跑半径：目标进入此范围 → 逃跑
@export var flee_range := 3.0
## 逃生后重置巡逻的距离
@export var escape_range := 14.0
## 追逐的目标（玩家），由外部指定
@export var target: Node3D
## 是否开启 RVO 动态避障（配合 NavigationObstacle3D 演示）
@export var avoidance_enabled := false

var navigation_agent: NavigationAgent3D
var _body: MeshInstance3D
var _state: int = AIState.PATROL
var _needs_target := true


func _ready() -> void:
	navigation_agent = NavigationAgent3D.new()
	navigation_agent.radius = agent_radius
	navigation_agent.height = 1.6
	navigation_agent.path_desired_distance = 0.3
	navigation_agent.target_desired_distance = 0.5
	navigation_agent.max_speed = move_speed
	navigation_agent.avoidance_enabled = avoidance_enabled
	if avoidance_enabled:
		navigation_agent.velocity_computed.connect(_on_velocity_computed)
	add_child(navigation_agent)
	# 简单圆柱身体
	_body = MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.35
	mesh.height = 1.4
	_body.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.3, 0.25)
	_body.material_override = mat
	add_child(_body)
	# 等几帧让导航网格同步到 NavigationServer 后再请求目标
	for i in 3:
		await get_tree().process_frame
	_enter_patrol()


## 状态切换时刷新目标点
func _enter_patrol() -> void:
	_state = AIState.PATROL
	_body.material_override.albedo_color = Color(0.9, 0.3, 0.25)
	_request_random_target()


func _enter_chase() -> void:
	_state = AIState.CHASE
	_body.material_override.albedo_color = Color(0.95, 0.55, 0.2)
	if target:
		navigation_agent.target_position = target.global_position
		_needs_target = false


func _enter_flee() -> void:
	_state = AIState.FLEE
	_body.material_override.albedo_color = Color(0.3, 0.6, 0.95)
	_request_flee_target()


func _request_random_target() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var angle := rng.randf() * TAU
	var dist := rng.randf() * patrol_radius
	var offset := Vector3(cos(angle), 0, sin(angle)) * dist
	var t := patrol_center + offset
	t.y = patrol_center.y
	navigation_agent.target_position = t
	_needs_target = false


## 逃跑：朝远离目标的方向取一点
func _request_flee_target() -> void:
	if target == null:
		_enter_patrol()
		return
	var away := (global_position - target.global_position)
	away.y = 0.0
	if away.length_squared() < 0.01:
		away = Vector3(1, 0, 0)
	away = away.normalized()
	var t := global_position + away * escape_range
	t.y = patrol_center.y
	navigation_agent.target_position = t
	_needs_target = false


func _physics_process(_delta: float) -> void:
	if navigation_agent == null:
		return
	_update_state()
	if navigation_agent.is_navigation_finished():
		# 到达目标或目标不可达 → 按状态处理
		if _state == AIState.CHASE and target:
			# 追逐目标可能已移动，刷新
			navigation_agent.target_position = target.global_position
			_needs_target = false
		elif _state == AIState.FLEE:
			# 逃到安全距离就回巡逻
			_enter_patrol()
		elif _state == AIState.PATROL:
			_request_random_target()
		return
	var next := navigation_agent.get_next_path_position()
	var to_next := next - global_position
	to_next.y = 0.0
	if to_next.length() < 0.01:
		if _state == AIState.CHASE and target:
			navigation_agent.target_position = target.global_position
		elif _state == AIState.FLEE:
			_enter_patrol()
		else:
			_request_random_target()
		return
	var desired := to_next.normalized() * move_speed
	if avoidance_enabled:
		# RVO 避障：把期望速度交给 NavigationAgent，等 velocity_computed 回调再实际移动
		velocity = Vector3.ZERO
		navigation_agent.set_velocity(desired)
	else:
		velocity = desired
		move_and_slide()
		_face_velocity()


## RVO 避障回调：拿到安全速度后移动
func _on_velocity_computed(safe_velocity: Vector3) -> void:
	safe_velocity.y = 0.0
	velocity = safe_velocity
	move_and_slide()
	_face_velocity()


func _face_velocity() -> void:
	if velocity.length() > 0.1:
		var target_yaw := atan2(velocity.x, velocity.z)
		_body.rotation.y = lerp_angle(_body.rotation.y, target_yaw, 0.15)


## 依据与目标的距离切换状态
func _update_state() -> void:
	if target == null:
		if _state != AIState.PATROL:
			_enter_patrol()
		return
	var dist := global_position.distance_to(target.global_position)
	match _state:
		AIState.PATROL:
			if dist <= flee_range:
				_enter_flee()
			elif dist <= chase_range:
				_enter_chase()
		AIState.CHASE:
			if dist <= flee_range:
				_enter_flee()
			elif dist > chase_range:
				_enter_patrol()
		AIState.FLEE:
			if dist > escape_range:
				_enter_patrol()
