class_name AttributeComponent extends Component

@export_dir var defs_dir: String = "res://Assets/Def/Attribute"

signal attribute_changed(attribute: Attribute, modifier: Modifier)

var attributes: Array[Attribute] = []

func get_def(attribute_name: String) -> AttributeDef:
	return load(defs_dir.path_join(attribute_name + ".tres"))

func get_attribute(attribute_name: String) -> Attribute:
	for attribute in attributes:
		if attribute.def.name == attribute_name:
			return attribute
	var def: AttributeDef = get_def(attribute_name)
	var attribute = Attribute.new(def)
	attributes.append(attribute)
	attribute.value_changed.connect(_on_attr_value_changed.bind(attribute))
	return attribute

func _on_attr_value_changed(modifier: Modifier, attr: Attribute):
	attribute_changed.emit(attr, modifier)

func get_value(attribute_name: String) -> int:
	return get_attribute(attribute_name).value

func set_value(attribute_name: String, value: int):
	get_attribute(attribute_name).value = value

func add_modifier(modifier: Modifier):
	get_attribute(modifier.attr_name).add_modifier(modifier)

func remove_modifiers(source: String):
	for attr in attributes:
		attr.remove_modifiers(source)

func clear_modifiers(source: String = ""):
	for attr in attributes:
		attr.clear_modifiers(source)

func game_ready():
	clear()

func clear():
	for attribute in attributes:
		attribute.reset()

func save_data():
	var data := {}
	for attr in attributes:
		data[attr.def.name] = attr.base_value
	return data

func load_data(data):
	if not data:
		return
	clear()
	for attr_name in data:
		var attr := get_attribute(attr_name)
		attr.base_value = data[attr_name]
