class_name TweenView extends Control

@export var tween: TweenAnimation

@export var tween_visible: bool = true:
	set(value):
		if tween_visible == value:
			return
		tween_visible = value
		_update_visible(false)

func _ready() -> void:
	_update_visible(true)

func _update_visible(reset: bool):
	TweenViewTool.update_visible(tween, tween_visible, reset)

func exit_container():
	var pos := global_position
	var container := get_parent()
	if container is Container:
		var container_node := container as Container
		container_node.remove_child(self )
		_new_parent.call_deferred(container_node, pos)

func _new_parent(container, pos: Vector2):
	if not is_instance_valid(container):
		return
	var new_parent = container.get_parent()
	if not is_instance_valid(new_parent):
		return
	new_parent.add_child(self )
	global_position = pos

func tween_free() -> void:
	exit_container()
	TweenViewTool.finish_and_free(self , tween)
