@tool
extends Node3D

## 资产光照贴图演示。流程：
##   1. 打开场景即自动生成 6 个带 UV2 的示例网格（`PrimitiveMesh` 只有 UV，必须转成 `ArrayMesh` 才有 UV2）；
##   2. 选中 `AssetLightmapStage` 点「烘焙并导出」——副本自动同步，烘焙按机器要几十秒；
##   3. 运行场景：光照库按场景路径自动接管，按钮可整体调亮度 / 开关光。
##
## 没烘过也能跑：实例只显示「无烘焙数据」，场景本身照常可交互。

const MESH_DIR := "res://Scenes/Lightmap/Meshes"
const MESH_COUNT := 6
const PER_ROW := 3
const SPACING := 2.2

@onready var _grid: Node3D = %Grid


func _ready() -> void:
	generate_meshes()
	_build_grid()
	if Engine.is_editor_hint():
		if not ResourceLoader.exists(AssetLightmapSet.path_of(scene_file_path)):
			LogTool.log("光照演示", "还没有烘焙产物：选中 AssetLightmapStage 点「烘焙并导出」")
		return
	## 只认本场景自己的产物；没有产物时 attach 返回 null 且不改动当前库
	AssetLightmapSet.attach(scene_file_path)
	%StrengthOff.pressed.connect(_set_strength.bind(0.0))
	%StrengthHalf.pressed.connect(_set_strength.bind(0.2))
	%StrengthFull.pressed.connect(_set_strength.bind(1.0))
	%Toggle.pressed.connect(_toggle_light)
	%State.text = "已接管光照库（无产物时会显示「无烘焙数据」）"


## 生成示例网格：盒体每面的 UV 就是 0..1 的独立岛，直接当 UV2 用，LightmapGI 才能按面铺光
func generate_meshes() -> void:
	if not DirAccess.dir_exists_absolute(MESH_DIR):
		DirAccess.make_dir_recursive_absolute(MESH_DIR)
	for i in MESH_COUNT:
		var path := "%s/Box_%d.tres" % [MESH_DIR, i]
		if ResourceLoader.exists(path):
			continue
		var mesh := _box_mesh(1.0 + i * 0.1)
		mesh.resource_name = path.get_file().get_basename()
		var err := ResourceSaver.save(mesh, path)
		if err != OK:
			LogTool.warn("光照演示", "示例网格保存失败:", path, err)


func _box_mesh(size: float) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = Vector3.ONE * size
	var arrays := box.surface_get_arrays(0)
	arrays[Mesh.ARRAY_TEX_UV2] = arrays[Mesh.ARRAY_TEX_UV]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## 展示网格由脚本铺：示例网格是编辑器生成的资源，场景里不写死引用
func _build_grid() -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	var paths := _mesh_paths()
	for i in paths.size():
		var mi := BakedMeshInstance3D.new()
		mi.name = "Box_%d" % i
		mi.mesh = load(paths[i])
		mi.position = Vector3((i % PER_ROW) * SPACING - SPACING, (i / PER_ROW) * SPACING * 0.6, 0.0)
		_grid.add_child(mi)


func _mesh_paths() -> PackedStringArray:
	var out := PackedStringArray()
	for i in MESH_COUNT:
		var path := "%s/Box_%d.tres" % [MESH_DIR, i]
		if ResourceLoader.exists(path):
			out.append(path)
	return out


func _set_strength(value: float) -> void:
	BakedMeshInstance3D.set_strength(value)
	%State.text = "叠加光亮度 %.2f（0 = 关）" % value


func _toggle_light() -> void:
	BakedMeshInstance3D.set_all_visible(not BakedMeshInstance3D.all_visible)
	%State.text = "全局光：%s" % ("开" if BakedMeshInstance3D.all_visible else "关")
