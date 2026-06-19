@tool
@warning_ignore("INTEGER_DIVISION")
class_name BakedPoolManager extends Node3D

static var singleton: BakedPoolManager

static func find_pool(key: String) -> BakedPool:
	if not singleton:
		return null
	return singleton.find_child(key, false)

static func pool_get(key: String) -> Node3D:
	if singleton:
		var pool := singleton.find_child(key, false)
		if pool is BakedPool:
			return pool.pool_get()
		printerr("不存在[", key, "]对象池 ")
	return null

static func pool_push(key: String, item: Node3D):
	if not item:
		return
	if Engine.is_editor_hint():
		item.queue_free()
		return
	if singleton:
		var pool := singleton.find_child(key, false)
		if pool is BakedPool:
			pool.pool_push(item)
			return
	printerr("不存在[", key, "]对象池 ")
	item.queue_free()

func _enter_tree() -> void:
	singleton = self

@export_dir var pool_dir: Array[String]

@export var mesh_pools: Dictionary[ArrayMesh, int]

@export var scene_pools: Dictionary[PackedScene, int]

@export var gap: float = 1.0

const SIZE = 10

@export_tool_button("刷新对象池") var create_pools_button = _create_pools

func _create_pools() -> void:
	if not Engine.is_editor_hint():
		return

	for dir_path in pool_dir:
		var dir = DirAccess.open(dir_path)
		if not dir:
			continue
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name:
			var res := ResourceLoader.load(dir_path.path_join(file_name))
			if res is ArrayMesh and not mesh_pools.has(res):
				mesh_pools[res as ArrayMesh] = 3
			elif res is PackedScene and not scene_pools.has(res):
				scene_pools[res as PackedScene] = 3
			file_name = dir.get_next()


	var current_x := 0.0
	var current_z := 0.0
	var pool_count := 0

	for mesh in mesh_pools:
		if not mesh:
			continue
		var pool := await _create_mesh_pool(mesh, mesh_pools[mesh])
		pool.position = Vector3(current_x, 0.0, current_z)

		pool_count += 1
		current_x += gap

		if pool_count % SIZE == 0:
			current_x = 0.0
			current_z += gap

	for scene in scene_pools:
		if not scene:
			continue
		var pool := await _create_scene_pool(scene, scene_pools[scene])
		pool.position = Vector3(current_x, 0.0, current_z)

		pool_count += 1
		current_x += gap

		if pool_count % SIZE == 0:
			current_x = 0.0
			current_z += gap

func _create_mesh_pool(mesh: ArrayMesh, count: int) -> BakedPool:
	var key := mesh.resource_path.get_file().get_basename()
	var mesh_pool := find_child(key, false)
	if mesh_pool:
		if mesh_pool.get_child_count() == count:
			return mesh_pool
		mesh_pool.queue_free()
		await mesh_pool.tree_exited

	mesh_pool = BakedPool.new()
	mesh_pool.name = key
	add_child(mesh_pool)
	mesh_pool.owner = self

	for i in count:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.name = str(key, '_', i + 1)
		mesh_pool.add_child(mesh_instance)
		mesh_instance.owner = self

	LogTool.log("烘焙池", "创建", key, "数量:", count, "=>", mesh_pool)
	return mesh_pool

func _create_scene_pool(scene: PackedScene, count: int) -> BakedPool:
	var key := scene.resource_path.get_file().get_basename()
	var mesh_pool := find_child(key, false)
	if mesh_pool:
		if mesh_pool.get_child_count() == count:
			return mesh_pool
		mesh_pool.queue_free()
		await mesh_pool.tree_exited

	mesh_pool = BakedPool.new()
	mesh_pool.name = key
	add_child(mesh_pool)
	mesh_pool.owner = self

	for i in count:
		var item := scene.instantiate()
		item.name = str(key, '_', i + 1)
		mesh_pool.add_child(item)
		item.owner = self

	LogTool.log("烘焙池", "创建", key, "数量:", count, "=>", mesh_pool)
	return mesh_pool
