class_name Button3D extends Area3D

@export var enter_tween: TweenAnimation
@export var press_tween: TweenAnimation

@export var visible_tween: TweenAnimation
@export var tween_visible: bool = true:
	set(value):
		if tween_visible == value:
			return
		tween_visible = value
		_update_visible(false)

@export var audio: SFXComponent
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

var is_pressed: bool

signal button_down()
signal button_up()

func _ready() -> void:
	_update_visible(true)

func _update_visible(reset: bool):
	TweenViewTool.update_visible(visible_tween, tween_visible, reset)

func _mouse_enter():
	if enter_tween:
		enter_tween.play()
	if audio:
		audio.play("Enter")

func _mouse_exit():
	if enter_tween:
		enter_tween.playback()
	if press_tween:
		press_tween.playback()

func _mouse_down():
	is_pressed = true
	if press_tween:
		press_tween.play()
	elif enter_tween:
		enter_tween.playback()
	_button_down()
	if audio:
		audio.play("Down")

func _mouse_up():
	if not is_pressed:
		return
	is_pressed = false
	if press_tween:
		press_tween.playback()
	elif enter_tween:
		enter_tween.play()
	_button_up()

func _button_down():
	button_down.emit()

func _button_up():
	button_up.emit()

func _input_event(_camera: Camera3D, event: InputEvent, event_position: Vector3, _normal: Vector3, _shape_idx: int):
	_game_input(event, event_position)

func _game_input(event: InputEvent, _event_position: Vector3):
	if event is InputEventMouseButton:
		var button_event: InputEventMouseButton = event
		if button_event.button_index == MOUSE_BUTTON_LEFT:
			if button_event.is_pressed():
				_mouse_down()
			elif button_event.is_released():
				_mouse_up()
