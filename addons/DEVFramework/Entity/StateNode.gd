class_name StateNode extends Node

signal state_entered()
signal state_exited()

var current_state: StateNode:
	set(value):
		if current_state == value:
			return
		if current_state:
			current_state._exit_state()
		current_state = value
		if current_state:
			current_state._enter_state()


func set_active_state(state_name: String) -> bool:
	if current_state and current_state.set_active_state(state_name):
		return true
	if state_name == name:
		return true
	for state: StateNode in get_children():
		if state.set_active_state(state_name):
			current_state = state
			return true
	return false

func get_active_state() -> String:
	if current_state:
		return current_state.get_active_state()
	else:
		return name

func is_state(state_name: String) -> bool:
	if current_state:
		return current_state.is_state(state_name)
	else:
		return name == state_name

func _enter_state():
	state_entered.emit()
	if current_state:
		current_state._enter_state()

func _exit_state():
	state_exited.emit()
	if current_state:
		current_state._exit_state()
