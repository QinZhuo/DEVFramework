class_name Modifier extends RefCounted

enum Mode { VALUE, PERCENT }

var source
var attr_name: String
var value: int
var mode: Mode

func _init(p_source, p_attr: String, p_value: int, p_mode: Mode = Mode.VALUE):
	source = p_source
	attr_name = p_attr
	value = p_value
	mode = p_mode

func apply_to(base: int) -> int:
	match mode:
		Mode.VALUE:
			return base + value
		Mode.PERCENT:
			return base * value / 100
	return base

func _to_string():
	return "[Modifier src=%s attr=%s val=%d mode=%d]" % [source, attr_name, value, mode]
