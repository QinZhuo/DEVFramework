@tool
@abstract class_name EffectDef extends Def

@abstract func apply(context)

func revert(context):
	printerr("cannot revert ", self )

func get_desc(context) -> String:
	return _to_string()

func _to_string() -> String:
	return get_script().get_global_name()
