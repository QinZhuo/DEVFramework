class_name DemoEntityBallNode
extends Entity2D

## Entity 节点写法(ECS↔Node 桥接)的实体节点 —— 继承 Entity2D 的独立脚本。
## 数据直接在节点上声明: 下方 @export 纯数据变量即组件 schema(无需单独的 ECSComponent 资源),
## 通过 register_to_ecs() 注册进 ECS 并把初值写入列; 显示/逻辑在节点上, 每帧高频逻辑由系统批量处理。

## —— 数据字段(ECS 组件 schema) ——
## 规则: 当前脚本直接声明的 @export / @export_storage 纯数据变量 = ECS 数据(自动注册进 ECS)。
## 位置直接用 Vector2 类型(pos/vel), 不拆分 x/y —— register_to_ecs 自动绑定 pos 为位置字段。
@export var pos: Vector2 = Vector2.ZERO
@export var vel: Vector2 = Vector2.ZERO
@export var hp: float = 100.0
@export var max_hp: float = 100.0
@export var dir: int = 1      # +1 增 / -1 减
@export var size: float = 0.0

## —— 显示/配置(@export 可编辑, 但排除出 ECS 数据) ——
@export var color: Color = Color(1.0, 0.7, 0.3)
const ECS_EXCLUDE := ["color"]
var max_ball_size: float = 8.0
var _visual_size: float = 5.0
var visual_size: float:
	get:
		return _visual_size
	set(v):
		_visual_size = v
		queue_redraw()   # 显示边长变化自动重绘(可被 ECSSyncSystem 规则同步)


func _draw() -> void:
	var s := max_ball_size * visual_size / 100.0
	if s < 0.5:
		return
	draw_rect(Rect2(-s * 0.5, -s * 0.5, s, s), color)
