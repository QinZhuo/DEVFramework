@tool
class_name AttributeDef extends EntityDef

func set_value(target, new_value: int) -> int:
	if target is Attribute:
		target.value = new_value
		return target.value
	elif name in target:
		target[name] = new_value
		return target[name]
	push_error("不存在 ", self , " 在 ", target)
	return 0

func get_value(target) -> int:
	if target is Attribute:
		return target.value
	elif name in target:
		return target[name]
	push_error("不存在 ", self , " 在 ", target)
	return 0

func change_value(target, offset: int) -> int:
	return set_value(target, get_value(target) + offset)
