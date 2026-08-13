extends CharacterBody3D
## 演示用玩家角色 — 简单移动，作为 NPC 三态 AI 的追逐/逃跑目标
##
## WASD/方向键移动，空格跳。网格高度固定 1，仅做平面移动（导航面上）。

@export var move_speed := 6.0

var _body: MeshInstance3D


func _ready() -> void:
	_body = MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.35
	mesh.height = 1.4
	_body.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.85, 0.35)
	_body.material_override = mat
	add_child(_body)


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
	velocity = dir * move_speed
	move_and_slide()
