@tool
extends Node3D

## 资产光照贴图展厅：同一份烘焙光，展示不同材质对它的反应
## （哑光 / 金属 / 粗糙金属 / 自发光），以及"烘焙光 开 ↔ 关"的对比。
##
## 本场景只负责**展示**，烘焙在 `Scenes/Lightmap/LightmapBake.tscn`（工具场景，运行时不用）。
## 用法：
##   1. 打开本场景即自动生成示例资源（带 UV2 + 材质，写进 Meshes/）；
##   2. 打开 LightmapBake.tscn，点舞台的「烘焙并导出」；
##   3. 回到本场景运行：光照库按烘焙场景的路径接管，用 UI 对比开/关与亮度。
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
## 烘焙场景：产物跟着它走（`<烘焙场景>_lightmap_set.res`），所以这里要指到工具场景
@export_file("*.tscn") var bake_scene: String = "res://Scenes/Lightmap/LightmapBake.tscn"

@onready var _grid: Node3D = %Grid


func _ready() -> void:
	generate_assets()
	_build_grid()
	if Engine.is_editor_hint():
		_report("编辑器预览")
		return

	%StrengthOff.pressed.connect(_set_strength.bind(0.0))
	%StrengthLow.pressed.connect(_set_strength.bind(0.2))
	%StrengthFull.pressed.connect(_set_strength.bind(0.6))
	%Toggle.pressed.connect(_toggle_light)

	var lib := AssetLightmapSet.attach(bake_scene)
	if lib == null:
		%State.text = "没有烘焙产物 —— 打开 %s 点「烘焙并导出」后重跑" % bake_scene.get_file()
	else:
		## 0.35：实测峰值 0.79、无裁切；1.0 会把 1/4 的像素顶成纯白，材质差别全被压平
		BakedMeshInstance3D.set_strength(0.35)
		%State.text = "烘焙光已接管：%d 类资源（亮度 0.35）" % lib.regions.size()
	_report("运行")


## 生成示例资源：BoxMesh 只有 UV 没有 UV2，转成 ArrayMesh 并重排 UV2 才能烘
func generate_assets() -> void:
	if not DirAccess.dir_exists_absolute(MESH_DIR):
		DirAccess.make_dir_recursive_absolute(MESH_DIR)
	for key in ASSETS:
		var path := MESH_DIR.path_join(key + ".tres")
		## 用 FileAccess 而不是 ResourceLoader.exists：后者读编辑器缓存，
		## 刚删掉的资产仍会被判成"存在"，于是重建时被跳过、留下空目录
		if FileAccess.file_exists(path):
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


## 手搓盒子：BoxMesh 的 UV 是"展开贴图"布局，一个面在 UV 上只有一条零面积的线，
## 拿来当 UV2 时 LightmapGI 铺不出岛，烘完就是黑洞 + 斜条纹。
## 这里直接给出 6 个面（每面 4 顶点、自带独立 UV2 格、法线朝外），不依赖引擎网格的内部排布。
## 面内两个方向满足 u × v = 法线；索引 (0,2,1)(1,2,3) 是 Godot 的顺时针正面
const CELL := 0.32
const INNER := 0.29

func _build_mesh(cfg: Dictionary) -> ArrayMesh:
	var half: Vector3 = cfg["size"] * 0.5
	var faces := [
		[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
		[Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
		[Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)],
		[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
		[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)],
		[Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
	]
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var indices := PackedInt32Array()
	for f in faces.size():
		var n: Vector3 = faces[f][0]
		var u: Vector3 = faces[f][1]
		var v: Vector3 = faces[f][2]
		var base := verts.size()
		var cell := Vector2(f % 3, f / 3) * CELL + Vector2(0.01, 0.01)
		for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			verts.append(Vector3(n.x * half.x, n.y * half.y, n.z * half.z)
				+ Vector3(u.x * half.x, u.y * half.y, u.z * half.z) * corner.x
				+ Vector3(v.x * half.x, v.y * half.y, v.z * half.z) * corner.y)
			normals.append(n)
			var uv := (corner + Vector2.ONE) * 0.5
			uvs.append(uv)
			uv2.append(uv * INNER + cell)
		indices.append_array([base, base + 2, base + 1, base + 1, base + 2, base + 3])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material(cfg))
	return mesh


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
		if not FileAccess.file_exists(path):
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
