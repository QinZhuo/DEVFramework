class_name DemoEntityWorld
extends World

## Entity 节点写法(ECS↔Node 桥接)的场景化世界 —— 每个小球一个 DemoEntityBallNode
## (**继承 Entity2D**, 数据字段 @export 在节点上声明, 节点即数据组件), 高频逻辑由系统
## (DemoEntityBallSystem)列批量处理, 渲染同步在 tick 里从列读回节点。
## 系统在 ecsworld(ECSWorld Def)的 Inspector 里配置; 本脚本负责生成实体节点。
## 场景放在 impl_entity 脚本文件夹下, 由 ECSDemo 实例化/删除来切换实现。

@export var ball_count := 10000
@export var init_seed := 20260808

## 表格中显示的实现名(兼容 ECSDemo 调度)
var impl_name := "Entity节点写法"
var render_enabled := true

var nodes: Array[DemoEntityBallNode] = []


func _ready() -> void:
	super()          # World: 按 ecsworld(Def) 初始化世界 + 注册场景配置的系统
	_spawn()


## 每帧: ECS 列批量逻辑 + 渲染同步(从列读回节点位置/尺寸)。
func tick(delta: float) -> void:
	ecs.tick(delta)
	if render_enabled:
		var poscol: PackedVector2Array = ecs.get_column(DemoEntityBallNode, &"pos")
		var scol: PackedFloat32Array = ecs.get_column(DemoEntityBallNode, &"size")
		var n := mini(nodes.size(), poscol.size())
		for i in n:
			var node: DemoEntityBallNode = nodes[i]
			node.position = poscol[i]
			node.set_visual_size(scol[i])


func _spawn() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = init_seed
	for _i in ball_count:
		var pos := Vector2(rng.randf_range(20.0, 1140.0), rng.randf_range(20.0, 700.0))
		var ang := rng.randf() * TAU
		var spd := rng.randf_range(20.0, 60.0)
		var vel := Vector2(cos(ang) * spd, sin(ang) * spd)
		var hp := rng.randf_range(0.0, 100.0)
		# 继承 Entity2D 的实体节点(数据字段 @export 在节点上声明, 无需单独组件资源)
		var n := DemoEntityBallNode.new()
		n.world = ecs
		n.pos = pos
		n.vel = vel
		n.hp = hp
		n.max_hp = 100.0
		n.dir = 1
		n.register_to_ecs()   # 把本节点作为数据组件注册进 ECS
		add_child(n)
		n.set_process(false)
		nodes.append(n)
