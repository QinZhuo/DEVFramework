@tool
class_name DefMeshView extends Node3D

@export var def: Def:
	set(value):
		def = value
		if not def:
			return
		if 'mesh' in def:
			mesh = def.mesh
		elif def_mesh.has(def):
			mesh = def_mesh[def]

@export var def_mesh: Dictionary[Def, ArrayMesh]

@export var mesh: ArrayMesh:
	set(value):
		if value == mesh:
			return
		_remove_view()
		mesh = value
		_add_view()

var view: Node3D

func _enter_tree():
	_add_view()

func _exit_tree():
	_remove_view()

func _get_pool_key() -> String:
	return mesh.resource_path.get_file().get_basename()

func _add_view():
	if not mesh or view:
		return
	view = BakedPoolManager.pool_get(_get_pool_key())
	if not view:
		view = MeshInstance3D.new()
		view.mesh = mesh
	add_child(view)

func _remove_view():
	if not view:
		return
	if mesh:
		BakedPoolManager.pool_push(_get_pool_key(), view)
	else:
		view.queue_free()
	view = null
