class_name Grass extends Node2D
## 生态箱：食物资源。被兔进食后消失，并在延迟后于随机位置重生。

@export var radius: float = 5.0
@export var respawn_time: float = 6.0

var _regrowing := false


func _ready() -> void:
	add_to_group(&"grass")


func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, Color(0.30, 0.78, 0.38))
	draw_circle(Vector2(2.0, -2.0), radius * 0.45, Color(0.55, 0.95, 0.5))


func is_available() -> bool:
	return visible and not _regrowing


## 被进食：隐藏并安排重生
func eaten() -> void:
	if _regrowing:
		return
	_regrowing = true
	visible = false
	get_tree().create_timer(respawn_time).timeout.connect(_respawn)


func _respawn() -> void:
	if not is_inside_tree():
		return
	position = EcosystemWorld.rand_pos()
	visible = true
	_regrowing = false
	queue_redraw()
