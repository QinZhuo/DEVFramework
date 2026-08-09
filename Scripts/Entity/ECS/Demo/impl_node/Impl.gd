class_name DemoNodeImpl
extends DemoImpl

## 普通 Node 实现 —— 纯 OOP: 每个小球一个 Node2D(DemoNodeBall),
## 数据存对象属性, 逻辑写在 _process, **节点本身即显示**。
## 完全自包含: 创建/初始化/驱动/显示/销毁都在本文件夹内实现。

var balls: Array[DemoNodeBall] = []


func setup(count: int, seed: int, parent: Node) -> void:
	impl_name = "普通Node实现"
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for _i in count:
		# 随机小球初始数据(与另外两种实现同种子同布局)
		var ang := rng.randf() * TAU
		var spd := rng.randf_range(20.0, 60.0)
		var n := DemoNodeBall.new()
		n.position = Vector2(rng.randf_range(20.0, 1140.0), rng.randf_range(20.0, 700.0))
		n.vx = cos(ang) * spd
		n.vy = sin(ang) * spd
		n.hp = rng.randf_range(0.0, 100.0)
		parent.add_child(n)
		n.set_process(false)   # 由主循环手动驱动, 便于测耗时
		balls.append(n)


func tick(delta: float) -> void:
	for n in balls:
		n.render_enabled = render_enabled
		n._process(delta)


func teardown() -> void:
	for n in balls:
		n.queue_free()
	balls.clear()
