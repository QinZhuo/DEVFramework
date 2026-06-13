class_name TweenView3D extends Node3D

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
	if tween:
		if tween_visible:
			if reset:
				tween.play_reset()
			else:
				tween.play()
		else:
			tween.playback()

func exit_container():
	var pos := position
	var container := get_parent()
	if container is Node3D:
		var node3d_container := container as Node3D
		node3d_container.remove_child(self )
		_new_parent.call_deferred(node3d_container, pos)

func _new_parent(container, pos: Vector3):
	if not is_instance_valid(container):
		return
	var new_parent = container.get_parent()
	if not is_instance_valid(new_parent):
		return
	new_parent.add_child(self )
	position = pos

func tween_free() -> void:
	exit_container()
	TweenViewTool.finish_and_free(self , tween)
