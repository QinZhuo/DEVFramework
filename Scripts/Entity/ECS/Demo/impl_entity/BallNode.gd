class_name DemoEntityBallNode
extends Entity2D

## Entity 节点写法的实体节点 —— **继承 Entity2D** 的独立脚本:
##   · 用传统写法读写 schema 字段(继承 Entity2D 的 ecs 属性路由, 自动进 ECS 列)
##   · 自带显示(_draw 色块), 实体即节点即表现 —— 这就是 Entity2D "自己适合的方式"
##   · 每帧高频逻辑由系统(DemoEntityBallSystem)批量处理, 显示尺寸由 Impl 从列同步(缓存)

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
