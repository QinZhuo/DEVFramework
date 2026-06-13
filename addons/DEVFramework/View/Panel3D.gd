class_name Panel3D extends Node3D

@export var show_tween: TweenAnimation

var is_open: bool

signal opened()
signal closed()
signal opened_changed(opened: bool)

func open():
	if show_tween:
		await show_tween.play().finished
	is_open = true
	opened.emit()
	opened_changed.emit(true)

func close():
	if show_tween:
		await show_tween.playback().finished
	is_open = false
	closed.emit()
	opened_changed.emit(false)

func switch():
	if is_open:
		await close()
	else:
		await open()

func popup():
	open()
	await closed
