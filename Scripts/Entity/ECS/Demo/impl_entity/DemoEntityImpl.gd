class_name DemoEntityImpl
extends DemoImpl

## Entity 节点写法(ECS↔Node 桥接)实现 —— 定位为"更方便使用的 ECS 逻辑":
##   · 每个小球一个 DemoEntityBallNode(**继承 Entity2D**), 数据字段 @export 直接在节点上声明
##     (无需单独的 ECSComponent 组件资源, 节点脚本即 schema)
##   · 用 register_to_ecs() 把本节点作为数据组件注册进 ECS, 当前变量值自动写入列
##   · 每帧高频逻辑交给系统(DemoEntityBallSystem)列批量处理, 再从 ECS 列同步节点 position/尺寸
## 完全自包含: 世界创建/初始化/驱动/显示/销毁都在本文件夹内实现。

var world: ECSWorld = null
var attr_system: DemoEntityBallSystem = null
var nodes: Array[DemoEntityBallNode] = []


func setup(count: int, seed: int, parent: Node) -> void:
	impl_name = "Entity节点写法"
	world = ECSWorld.new(false)
	attr_system = DemoEntityBallSystem.new()
	world.register_system(attr_system)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for _i in count:
		# 随机小球初始数据(与另外两种实现同种子同布局)
		var pos := Vector2(rng.randf_range(20.0, 1140.0), rng.randf_range(20.0, 700.0))
		var ang := rng.randf() * TAU
		var spd := rng.randf_range(20.0, 60.0)
		var vel := Vector2(cos(ang) * spd, sin(ang) * spd)
		var hp := rng.randf_range(0.0, 100.0)
		# 创建继承 Entity2D 的实体节点(数据字段 @export 在节点上声明, 无需单独组件资源)
		var n := DemoEntityBallNode.new()
		n.world = world
		# 传统写法设初值(节点变量)
		n.pos = pos
		n.vel = vel
		n.hp = hp
		n.max_hp = 100.0
		n.dir = 1
		# 桥接: 把本节点作为数据组件注册进 ECS(自动注册组件 + 写初值 + 绑定位置)
		n.register_to_ecs()
		parent.add_child(n)
		n.set_process(false)   # 每帧逻辑由系统批量驱动
		nodes.append(n)


func tick(delta: float) -> void:
	# 每帧高频逻辑由系统列批量处理(ECS 底层加速)
	world.tick(delta)
	# 渲染同步(位置/大小 → 节点): 屏蔽渲染时跳过, 只做数值逻辑
	if render_enabled:
		var poscol: PackedVector2Array = world.get_column(DemoEntityBallNode, &"pos")
		var scol: PackedFloat32Array = world.get_column(DemoEntityBallNode, &"size")
		var n := mini(nodes.size(), poscol.size())
		for i in n:
			var node: DemoEntityBallNode = nodes[i]
			node.position = poscol[i]
			node.set_visual_size(scol[i])


func teardown() -> void:
	for n in nodes:
		n.queue_free()
	nodes.clear()
	world = null
