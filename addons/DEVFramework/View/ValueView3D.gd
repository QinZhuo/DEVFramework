@tool
class_name ValueView3D extends TweenView3D

@export var icon: Sprite3D
@export var back: Sprite3D
@export var label: Label3D
@export var value_tween: TweenAnimation

var data: Variant:
	set(value):
		if value:
			if value is Buff:
				if data:
					data.stacks_changed.disconnect(on_value_changed)
				value.stacks_changed.connect(on_value_changed)
				on_value_changed(value.stacks)
			elif value is Attribute:
				if data:
					data.value_changed.disconnect(_on_attr_changed)
				value.value_changed.connect(_on_attr_changed)
				on_value_changed(value.value)
			elif value is Symbol:
				if data:
					data.value_changed.disconnect(on_value_changed)
				value.value_changed.connect(on_value_changed)
				on_value_changed(value.value)
			elif 'value' in value:
				on_value_changed(value.value)
			elif value is TagDef:
				label.text = str(value)
				value = {def = value}
			else:
				label.text = on_value_changed(int(data))
			if 'def' in value:
				if icon:
					icon.texture = value.def.icon
				if back:
					back.modulate = value.def.color
				label.modulate = lerp(value.def.color, Color.WHITE, 0.6)
		data = value

func _on_attr_changed(_modifier: Modifier):
	if data is Attribute:
		on_value_changed(data.value)

func on_value_changed(new_value: int, _old_value: int = 0):
	if tween:
		tween_visible = new_value != 0
		if not tween_visible:
			return
	label.text = str(new_value)
	if value_tween:
		value_tween.play_reset()

func _mouse_enter():
	TipPanel.open_panel(self )

func _mouse_exit():
	TipPanel.close_panel(self )
