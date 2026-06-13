@abstract class_name Entity extends RefCounted

signal entity_changed()

func _init(init_def: EntityDef):
	if init_def:
		if "def" in self:
			set("def", init_def)
	else:
		push_error("init_def is null")

func _to_string():
	if "def" in self:
		return str(get("def"))
	return str(hash(self ))

func get_desc(data):
	if "def" in self:
		return get("def").get_desc(data)
	return _to_string()
