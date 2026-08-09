class_name DemoEntityImpl
extends DemoImpl

## Entity 节点写法实现 —— 传统 OOP 手感 + ECS 底层加速:
##   · 每个小球一个 DemoEntityBallNode(**继承 Entity2D 的独立脚本**, 自带显示 _draw)
##   · 初始化/配置用传统写法直接读写 schema 字段(node.hp = 80), 自动路由进 ECS 列
##   · 每帧高频逻辑交给系统(DemoEntityBallSystem)列批量处理, 再从 ECS 列同步节点 position/尺寸
## 完全自包含: 世界创建/初始化/驱动/显示/销毁都在本文件夹内实现。

var world: ECSWorld = null
var attr_system: DemoEntityBallSystem = null
var nodes: Array[DemoEntityBallNode] = []


func setup(count: int, seed: int, parent: Node) -> void:
	impl_name = "Entity节点写法"
	world = ECSWorld.new(false)
	world.register_component(DemoEntityBall)
	attr_system = DemoEntityBallSystem.new()
	world.register_system(attr_system)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for _i in count:
		# 随机小球初始数据(与另外两种实现同种子同布局)
		var ang := rng.randf() * TAU
		var spd := rng.randf_range(20.0, 60.0)
		var x := rng.randf_range(20.0, 1140.0)
		var y := rng.randf_range(20.0, 700.0)
		var vx := cos(ang) * spd
		var vy := sin(ang) * spd
		var hp := rng.randf_range(0.0, 100.0)
		# 创建继承 Entity2D 的实体节点
		var n := DemoEntityBallNode.new()
		n.world = world
		# [实验] 无 _set/_get 时初始化改用显式 set_field(数据进 ECS 列)
		n.set_field(DemoEntityBall, &"x", x)
		n.set_field(DemoEntityBall, &"y", y)
		n.set_field(DemoEntityBall, &"vx", vx)
		n.set_field(DemoEntityBall, &"vy", vy)
		n.set_field(DemoEntityBall, &"hp", hp)
		n.set_field(DemoEntityBall, &"max_hp", 100.0)
		n.set_field(DemoEntityBall, &"dir", 1)
		parent.add_child(n)
		n.set_process(false)   # 每帧逻辑由系统批量驱动
		nodes.append(n)


func tick(delta: float) -> void:
	# 每帧高频逻辑由系统列批量处理(ECS 底层加速)
	world.tick(delta)
	# 从 ECS 列同步节点位置与显示尺寸(每帧全量, 与另外两种实现同等负载保证公平对比)
	var xcol: PackedFloat32Array = world.get_column(DemoEntityBall, &"x")
	var ycol: PackedFloat32Array = world.get_column(DemoEntityBall, &"y")
	var scol: PackedFloat32Array = world.get_column(DemoEntityBall, &"size")
	var n := mini(nodes.size(), xcol.size())
	for i in n:
		var node: DemoEntityBallNode = nodes[i]
		node.position = Vector2(xcol[i], ycol[i])
		node.set_visual_size(scol[i])


func teardown() -> void:
	for n in nodes:
		n.queue_free()
	nodes.clear()
	world = null
