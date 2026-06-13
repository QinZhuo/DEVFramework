@tool
class_name BuffDef extends EntityDef

@export var tags: Array[BuffTagDef]

static var cleanse: BuffDef:
	get(): return load("res://Assets/Def/Buff/cleanse.tres")
