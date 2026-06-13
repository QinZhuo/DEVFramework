@tool
class_name PercentValueDef extends ValueDef

@export var value: ValueDef
@export var percent: ValueDef

func get_float(data) -> float:
	return value.get_float(data) * percent.get_float(data) / 100.0

func get_desc(data) -> String:
	return str(percent.get_desc(data), "%", value.get_desc(data))

func _to_string():
	return str(percent, "%", value)
