extends TestCase

## BakedMeshInstance3D × 光照库切换（必须游戏进程：要真进场景树才走 _enter_tree / 整体重挂）。
##
## 用合成图集代替真实烘焙产物（烘焙只能在编辑器里点按钮，测试不该依赖它），锁三件事：
## 1) 先入树、后设库 → 实例会自己补挂上光（此前会一直停在"无烘焙数据"）；
## 2) 全局开关关掉 → 摘光，再打开 → 重新挂上；
## 3) 库被清空 → 光擦干净，不留旧光。

const KEY := "TestBox"

var _nodes: Array[Node] = []


func needs_game_process() -> bool:
	return true


func cleanup() -> void:
	AssetLightmapSet.current = null
	AssetLightmapBinder._pairs.clear()
	AssetLightmapBinder.set_strength(0.2)
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _library() -> AssetLightmapSet:
	var img := Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1))
	var atlas := Texture2DArray.new()
	atlas.create_from_images([img, img, img, img])
	var data := LightmapGIData.new()
	data.uses_spherical_harmonics = true
	data.set_lightmap_textures([atlas])
	var region := AssetLightmapRegion.new()
	region.uv = Rect2(0, 0, 1, 1)
	var lib := AssetLightmapSet.new()
	lib.data = data
	lib.regions[KEY] = region
	return lib


## 带 UV2 的单面网格，键取自 resource_name（运行时网格没有路径）
func _mesh() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)])
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, StandardMaterial3D.new())
	mesh.resource_name = KEY
	return mesh


func _spawn() -> BakedMeshInstance3D:
	var mi := BakedMeshInstance3D.new()
	mi.mesh = _mesh()
	_nodes.append(mi)
	Engine.get_main_loop().root.add_child(mi)
	return mi


func test_library_set_after_entering_tree() -> void:
	var mi := _spawn()
	assert_eq(mi.lightmap_state, "无烘焙数据", "还没设库时不应挂光")

	AssetLightmapSet.current = _library()
	assert_eq(mi.lightmap_state, "已挂载", "设置库后已在树上的实例应自动补挂")
	assert_true(mi.get_surface_override_material(0) != null, "面材质应换成带 SH 叠加层的宿主")


func test_global_switch_and_clear() -> void:
	AssetLightmapSet.current = _library()
	var mi := _spawn()
	assert_eq(mi.lightmap_state, "已挂载", "进树即挂光")

	BakedMeshInstance3D.set_all_visible(false)
	assert_eq(mi.lightmap_state, "已关闭", "全局关光应摘掉")
	assert_true(mi.get_surface_override_material(0) == null, "关光后不应残留宿主材质")

	BakedMeshInstance3D.set_all_visible(true)
	assert_eq(mi.lightmap_state, "已挂载", "重新打开应挂回去")

	AssetLightmapSet.current = null
	assert_eq(mi.lightmap_state, "无烘焙数据", "库被清空后应摘光")
	assert_true(mi.get_surface_override_material(0) == null, "库清空后不应残留宿主材质")
