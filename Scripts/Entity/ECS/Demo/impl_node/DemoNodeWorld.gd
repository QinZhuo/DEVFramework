class_name DemoNodeWorld
extends Node

## 普通 Node 实现(纯 OOP)的场景化 —— 每个小球一个 DemoNodeBall 节点, 数据存对象属性,
## 逻辑写在 _process, **节点本身即显示**。本场景放在 impl_node 脚本文件夹下。
## 由 ECSDemo 实例化/删除本场景来切换实现。

@export var ball_count := 10000
@export var init_seed := 20260808

## 表格中显示的实现名(兼容 ECSDemo 调度)
var impl_name := "普通Node实现"
var render_enabled := true

var balls: Array[DemoNodeBall] = []


func _ready() -> void:
	_spawn()


func tick(delta: float) -> void:
	for n in balls:
		n.render_enabled = render_enabled
		n._process(delta)


func _spawn() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = init_seed
	for _i in ball_count:
		# 随机小球初始数据(与各实现同种子同布局)
		var ang := rng.randf() * TAU
		var spd := rng.randf_range(20.0, 60.0)
		var n := DemoNodeBall.new()
		n.position = Vector2(rng.randf_range(20.0, 1140.0), rng.randf_range(20.0, 700.0))
		n.vx = cos(ang) * spd
		n.vy = sin(ang) * spd
		n.hp = rng.randf_range(0.0, 100.0)
		add_child(n)
		n.set_process(false)   # 由 ECSDemo 手动驱动, 便于测耗时
		balls.append(n)
