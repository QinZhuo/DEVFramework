class_name DemoEntityBallNode
extends Entity2D

## Entity 节点写法(ECS↔Node 桥接)的实体节点 —— 继承 Entity2D 的独立脚本。
## 数据直接在节点上声明: 下方 @export 纯数据变量即组件 schema(无需单独的 ECSComponent 资源),
## 通过 register_to_ecs() 注册进 ECS 并把初值写入列; 显示/逻辑在节点上, 每帧高频逻辑由系统批量处理。

## —— 数据字段(即 ECS 组件 schema, 会注册进 ECS 列) ——
@export var x: float = 0.0
@export var y: float = 0.0
@export var vx: float = 0.0
@export var vy: float = 0.0
@export var hp: float = 100.0
@export var max_hp: float = 100.0
@export var dir: int = 1      # +1 增 / -1 减
@export var size: float = 0.0

## —— 显示/配置(非数据, 不注册进 ECS) ——
var color: Color = Color(1.0, 0.7, 0.3)
var max_ball_size: float = 8.0
var visual_size: float = 5.0   # 显示边长(缓存自 ECS 列 size)


func set_visual_size(v: float) -> void:
	visual_size = v
	queue_redraw()


func _draw() -> void:
	var s := max_ball_size * visual_size / 100.0
	if s < 0.5:
		return
	draw_rect(Rect2(-s * 0.5, -s * 0.5, s, s), color)
