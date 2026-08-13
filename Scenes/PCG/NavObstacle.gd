extends Node3D
## 可移动动态障碍物 — NavigationObstacle3D 演示
##
## 用方向键/WASD 控制移动。NavigationObstacle3D 参与 RVO 避障：
## 开启 avoidance 的 NPC 会自动绕开它（本脚本用 NavigationServer3D.obstacle API 实时同步位置）。

@export var move_speed := 5.0
@export var obstacle_radius := 1.2

var _obstacle: NavigationObstacle3D
var _ball: MeshInstance3D


func _ready() -> void:
	_obstacle = NavigationObstacle3D.new()
	_obstacle.radius = obstacle_radius
	_obstacle.height = 2.0
	_obstacle.avoidance_enabled = true
	add_child(_obstacle)
	_ball = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = obstacle_radius
	mesh.height = obstacle_radius * 2
	_ball.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.85, 0.2)
	_ball.material_override = mat
	add_child(_ball)


func _physics_process(_delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.z -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.z += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1
	if dir.length_squared() > 0:
		dir = dir.normalized()
	position += dir * move_speed * _delta
