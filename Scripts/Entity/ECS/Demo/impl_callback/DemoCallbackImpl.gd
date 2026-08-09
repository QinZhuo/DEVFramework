class_name DemoCallbackImpl
extends DemoImpl

## ECS 查询链回调实现 —— 实体数据存 ECS 列(DemoQueryBall), 逻辑由系统(DemoCallbackBallSystem)
## 用 for_each.with(字段).process(回调) 手写循环批量处理(借出列零跨语言)。
## 显示用独立的 DemoQueryBallNode(纯表现节点) + ECSSyncSystem 每帧从列同步。
## 与 impl_query(声明式 batch 多查询)共用同一组件/节点/同步布局, 仅逻辑层写法不同,
## 作为"声明式 batch vs 手写回调"两种查询链用法的性能对比参照。

var world: ECSWorld = null
var ball_system: DemoCallbackBallSystem = null
var sync_sys: ECSSyncSystem = null
var visuals: Array[DemoQueryBallNode] = []   # 每个实体一个显示节点


func setup(count: int, seed: int, parent: Node) -> void:
	impl_name = "ECS回调实现"
	world = ECSWorld.new(false)
	ball_system = DemoCallbackBallSystem.new()
	world.register_system(ball_system)   # register_system 自动注册 required_components
	sync_sys = ECSSyncSystem.new()
	sync_sys.add_field_rule(DemoQueryBall, &"pos", &"position")      # 位置
	sync_sys.add_field_rule(DemoQueryBall, &"size", &"visual_size")  # 大小
	world.register_system(sync_sys)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for _i in count:
		# 随机小球初始数据(与各实现同种子同布局)
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
		# 显示节点: 位置由 ECSSyncSystem 批量同步, 节点只做表现
		var v := DemoQueryBallNode.new()
		v.position = pos
		parent.add_child(v)
		v.set_process(false)
		visuals.append(v)
		# 挂 NodeLink 关联实体↔显示节点(只存 node_path, 同步字段由规则决定)
		world.add_component(e, NodeLink, {"node_path": str(v.get_path())})


func tick(delta: float) -> void:
	# 数值逻辑(DemoCallbackBallSystem) + 位置/字段同步(ECSSyncSystem) 都在 world.tick 内执行
	if sync_sys:
		sync_sys.render_enabled = render_enabled
	world.tick(delta)


func teardown() -> void:
	for v in visuals:
		v.queue_free()
	visuals.clear()
	world = null
