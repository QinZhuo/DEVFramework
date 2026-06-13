class_name EffectResult extends RefCounted

var def: EntityDef
var value: int
var next: EffectResult

func _init(value_def: EntityDef, effect_value) -> void:
	if not value_def:
		push_error("def is null")
	def = value_def
	value = effect_value

func _to_string() -> String:
	return str(def, ' ', value, ' ', next)
