@tool
extends Node3D

## 资产光照贴图展厅：同一份烘焙光，展示不同材质对它的反应
## （哑光 / 金属 / 粗糙金属 / 自发光），以及"烘焙光 开 ↔ 关"的对比。
##
## 用法：
##   1. 打开本场景即自动生成示例资源（带 UV2 + 材质，写进 Meshes/）；
##   2. 选中 Stage 点「烘焙并导出」（Quality 已设 Low，几秒钟一轮，方便反复调）；
##   3. 运行本场景：光照库按场景路径自动接管，用 UI 对比开/关与亮度。
##
## 没烘过也能跑：展品只是没有叠加光，Output 会打印实际挂载数量。

const MESH_DIR := "res://Scenes/Lightmap/Meshes"

## 展品清单：尺寸 + 材质。材质必须写进 .tres —— 烘焙舞台的副本是裸 MeshInstance3D，
## 只有网格自带材质，烘焙才会按这份 albedo / 自发光算光
const ASSETS := {
	"Pedestal": {"size": Vector3(1.6, 0.35, 1.6), "albedo": Color(0.3, 0.31, 0.35), "roughness": 0.85},
	"CubeWhite": {"size": Vector3.ONE, "albedo": Color(0.86, 0.86, 0.82), "roughness": 0.9},
	"CubeMatte": {"size": Vector3.ONE, "albedo": Color(0.2, 0.58, 0.54), "roughness": 0.95},
	"CubeMetal": {"size": Vector3.ONE, "albedo": Color(0.96, 0.96, 0.96), "roughness": 0.08, "metallic": 1.0},
	"CubeRoughMetal": {"size": Vector3.ONE, "albedo": Color(0.72, 0.54, 0.36), "roughness": 0.5, "metallic": 1.0},
	"Glow": {"size": Vector3(0.9, 0.22, 0.9), "albedo": Color(0.04, 0.04, 0.04), "roughness": 1.0, "glow": Color(1.0, 0.52, 0.18)},
}

## 展厅布置：资源键 → 实例位置。同一份资源摆多个，也共用同一份光照（这正是资产级方案的意义）
const LAYOUT := {
	"Pedestal": [Vector3(-2.6, 0.175, 0), Vector3(0, 0.175, 0), Vector3(2.6, 0.175, 0)],
	"CubeWhite": [Vector3(-2.6, 0.87, 0)],
	"CubeMatte": [Vector3(0, 0.87, 0)],
	"CubeMetal": [Vector3(2.6, 0.87, 0)],
	"CubeRoughMetal": [Vector3(-4.3, 0.5, 1.4)],
	"Glow": [Vector3(4.3, 0.65, -1.1)],
}

@export_tool_button("重新生成示例资源") var regenerate: Callable = rebuild_assets

@onready var _grid: Node3D = %Grid
@onready var _stage: Node3D = %Stage


func _ready() -> void:
	generate_assets()
	_build_grid()
	if Engine.is_editor_hint():
		_report("编辑器预览")
		return

	## 舞台只用来烘焙：副本与烘焙灯在运行时不该出现（它们摆在本场景之外）
	_stage.visible = false
	%StrengthOff.pressed.connect(_set_strength.bind(0.0))
	%StrengthLow.pressed.connect(_set_strength.bind(0.2))
	%StrengthFull.pressed.connect(_set_strength.bind(1.0))
	%Toggle.pressed.connect(_toggle_light)

	var lib := AssetLightmapSet.attach(scene_file_path)
	if lib == null:
		%State.text = "没有烘焙产物 —— 在编辑器里选中 Stage 点「烘焙并导出」后重跑"
	else:
		## 默认拉到 1.0，开/关的差别才够直观（框架默认值 0.2 是给正式项目用的保守值）
		BakedMeshInstance3D.set_strength(1.0)
		%State.text = "烘焙光已接管：%d 类资源" % lib.regions.size()
	_report("运行")


## 生成示例资源：BoxMesh 只有 UV 没有 UV2，转成 ArrayMesh 并重排 UV2 才能烘
func generate_assets() -> void:
	if not DirAccess.dir_exists_absolute(MESH_DIR):
		DirAccess.make_dir_recursive_absolute(MESH_DIR)
	for key in ASSETS:
		var path := MESH_DIR.path_join(key + ".tres")
		if ResourceLoader.exists(path):
			continue
		var mesh := _build_mesh(ASSETS[key])
		mesh.resource_name = key
		var err := ResourceSaver.save(mesh, path)
		if err != OK:
			LogTool.warn("光照演示", "示例资源保存失败:", path, err)


## 改了 ASSETS 里的尺寸/材质后用：删掉旧资源重建
func rebuild_assets() -> void:
	for key in ASSETS:
		var path := MESH_DIR.path_join(key + ".tres")
		if ResourceLoader.exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	generate_assets()
	_build_grid()


func _build_mesh(cfg: Dictionary) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = cfg["size"]
	var arrays := box.surface_get_arrays(0)
	arrays[Mesh.ARRAY_TEX_UV2] = _face_uv2(arrays[Mesh.ARRAY_TEX_UV])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material(cfg))
	return mesh


## 盒体 UV 每个面都是 0..1 的**重叠**岛，直接当 UV2 会 6 面共采样同一片光照。
## 按面拆到 3×2 的小格里，每面各占一块（顶点按面连续 4 个一组）
func _face_uv2(uv: PackedVector2Array) -> PackedVector2Array:
	const CELL := 0.32
	const INNER := 0.29
	var out := PackedVector2Array()
	out.resize(uv.size())
	for i in uv.size():
		var face := i / 4
		var origin := Vector2(face % 3, face / 3) * CELL + Vector2(0.01, 0.01)
		out[i] = uv[i] * INNER + origin
	return out


func _material(cfg: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = cfg["albedo"]
	mat.roughness = cfg.get("roughness", 0.8)
	mat.metallic = cfg.get("metallic", 0.0)
	if cfg.has("glow"):
		mat.emission_enabled = true
		mat.emission = cfg["glow"]
		mat.emission_energy_multiplier = 6.0
	return mat


## 展品按 LAYOUT 摆放：位置写在脚本里，场景文件不必引用生成的资源
func _build_grid() -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	for key in LAYOUT:
		var path := MESH_DIR.path_join(key + ".tres")
		if not ResourceLoader.exists(path):
			continue
		var mesh: ArrayMesh = load(path)
		var spots: Array = LAYOUT[key]
		for i in spots.size():
			var mi := BakedMeshInstance3D.new()
			mi.name = "%s_%d" % [key, i]
			mi.mesh = mesh
			mi.position = spots[i]
			_grid.add_child(mi)


## 排查"烘了却没效果"最快的一条信息：几个实例真的挂上了光
func _report(stage: String) -> void:
	var mounted := 0
	var total := 0
	for child in _grid.get_children():
		if child is BakedMeshInstance3D:
			total += 1
			if (child as BakedMeshInstance3D).lightmap_state == "已挂载":
				mounted += 1
	LogTool.log("光照演示", "%s：已挂光 %d/%d 个实例" % [stage, mounted, total])


func _set_strength(value: float) -> void:
	BakedMeshInstance3D.set_strength(value)
	%State.text = "叠加光亮度 %.2f（0 = 只剩实时灯）" % value


func _toggle_light() -> void:
	BakedMeshInstance3D.set_all_visible(not BakedMeshInstance3D.all_visible)
	%State.text = "烘焙光：%s" % ("开" if BakedMeshInstance3D.all_visible else "关（只剩实时灯 + 环境光）")
