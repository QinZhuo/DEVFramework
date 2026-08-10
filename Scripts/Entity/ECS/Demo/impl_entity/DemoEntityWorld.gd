class_name DemoEntityWorld
extends World

## Entity 节点写法(ECS↔Node 桥接)的场景化世界 —— 每个小球一个 DemoEntityBallNode
## (继承 Entity2D, 节点即数据组件), 高频逻辑由系统(DemoEntityBallSystem)列批量处理,
## 渲染同步同样交给 ECSSyncSystem(场景 field_rules 配置 DemoEntityBallNode.pos→position / size→visual_size)。
## 系统与同步规则都在场景 Inspector 配置(systems + field_rules); 本脚本只负责生成实体节点。
## 场景放在 impl_entity 脚本文件夹下, 由 ECSDemo 实例化/删除来切换实现。

@export var ball_count := 10000
@export var init_seed := 20260808

var nodes: Array[DemoEntityBallNode] = []


func _ready() -> void:
	super()          # World: 创建 ECSWorld + 注册场景配置的系统(含 ECSSyncSystem)
	_spawn()


## 生成继承 Entity2D 的实体节点(数据字段 @export 在节点上声明, 节点即数据组件)。
func _spawn() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = init_seed
	for _i in ball_count:
		var pos := Vector2(rng.randf_range(20.0, 1140.0), rng.randf_range(20.0, 700.0))
		var ang := rng.randf() * TAU
		var spd := rng.randf_range(20.0, 60.0)
		var vel := Vector2(cos(ang) * spd, sin(ang) * spd)
		var hp := rng.randf_range(0.0, 100.0)
		var n := DemoEntityBallNode.new()
		n.world = ecs
		n.pos = pos
		n.vel = vel
		n.hp = hp
		n.max_hp = 100.0
		n.dir = 1
		n.register_to_ecs()   # 把本节点作为数据组件注册进 ECS(含 NodeLink 关联)
		add_child(n)         # 入树后 Entity2D 刷新 NodeLink.node_path
		n.set_process(false)
		nodes.append(n)
