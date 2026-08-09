class_name DemoQueryImpl
extends DemoImpl

## ECS 查询链实现 —— 实体数据存 ECS 列(DemoQueryBall), 逻辑由系统(DemoQueryBallSystem)
## 用 for_each 查询链批量处理; 显示用独立的 DemoQueryBallNode(纯表现节点), 每帧从列同步。
## 完全自包含: 世界创建/初始化/驱动/显示/销毁都在本文件夹内实现。
## 本实现特有的"写法": 实体是 int ID, 用 world API 操作数据。

var world: ECSWorld = null
var ball_system: DemoQueryBallSystem = null
var visuals: Array[DemoQueryBallNode] = []   # 每个实体一个显示节点


func setup(count: int, seed: int, parent: Node) -> void:
	impl_name = "ECS查询链实现"
	world = ECSWorld.new(false)
	ball_system = DemoQueryBallSystem.new()
	world.register_system(ball_system)   # register_system 自动注册 required_components
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for _i in count:
		# 随机小球初始数据(与另外两种实现同种子同布局)
		var pos := Vector2(rng.randf_range(20.0, 1140.0), rng.randf_range(20.0, 700.0))
		var ang := rng.randf() * TAU
		var spd := rng.randf_range(20.0, 60.0)
		var vel := Vector2(cos(ang) * spd, sin(ang) * spd)
		var hp := rng.randf_range(0.0, 100.0)
		# 实体数据进 ECS 列
		var e := world.create_entity()
		world.add_component(e, DemoQueryBall)
		world.set_field(e, DemoQueryBall, &"pos", pos)
		world.set_field(e, DemoQueryBall, &"vel", vel)
		world.set_field(e, DemoQueryBall, &"hp", hp)
		# 显示节点: 位置/大小由系统同步, 节点只做表现
		var v := DemoQueryBallNode.new()
		v.position = pos
		parent.add_child(v)
		v.set_process(false)
		visuals.append(v)


func tick(delta: float) -> void:
	world.tick(delta)
	# 渲染同步(位置/大小 → 显示节点): 屏蔽渲染时跳过, 只做数值逻辑
	if render_enabled:
		var poscol: PackedVector2Array = world.get_column(DemoQueryBall, &"pos")
		var scol: PackedFloat32Array = world.get_column(DemoQueryBall, &"size")
		var n := mini(visuals.size(), poscol.size())
		for i in n:
			var v: DemoQueryBallNode = visuals[i]
			v.position = poscol[i]
			v.set_visual_size(scol[i])


func teardown() -> void:
	for v in visuals:
		v.queue_free()
	visuals.clear()
	world = null
