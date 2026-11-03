extends TestCase

## 资产光照贴图回归（纯逻辑 + 内存网格，编辑器进程即可；不依赖 LightmapGI 烘焙）。
##
## 锁定的是「静默错」级别的语义：
## 1) 缺 UV2 的面只跳过自己，不拖累同一模型上有 UV2 的面；
## 2) 摘光（clear）要还原成挂光之前的材质，业务自设的 surface override 不能丢；
## 3) 材质副本按「光照 + 基材质」共用，换库时按光照整体回收；
## 4) 路径与键规则（场景产物路径、副本节点名 → 资源键）。

const ATLAS_SIZE := 4


func cleanup() -> void:
	AssetLightmapBinder._pairs.clear()
	AssetLightmapBinder._bakeable.clear()
	AssetLightmapBinder.set_strength(0.2)
	AssetLightmapSet.current = null


## ---- 夹具 ----

func _atlas() -> TextureLayered:
	var img := Image.create(ATLAS_SIZE, ATLAS_SIZE, false, Image.FORMAT_RGBA8)
	var tex := Texture2DArray.new()
	tex.create_from_images([img, img, img, img])
	return tex


func _region() -> AssetLightmapRegion:
	var light := AssetLightmapRegion.new()
	light.uv = Rect2(0.0, 0.0, 0.5, 0.5)
	light.slice = 0
	return light


## [param flags] 每个元素 = 该面是否有 UV2（true = 可叠加）。
## 每面都带一份标准材质：没有材质的 surface 会被 binder 当成"不可叠加"直接跳过
func _mesh(flags: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for has_uv2: bool in flags:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
			Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
			Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1)])
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
			Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)])
		if has_uv2:
			arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([
				Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, StandardMaterial3D.new())
	return mesh


func _instance(mesh: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


## ---- 路径与键 ----

func test_path_of() -> void:
	assert_eq(AssetLightmapSet.path_of("res://Scenes/A/B.tscn"), "res://Scenes/A/B_lightmap_set.res")
	assert_eq(AssetLightmapSet.path_of(""), "", "空路径不推导产物路径")


func test_key_of_copy_path() -> void:
	assert_eq(AssetLightmapStage._key_of_path("../CardBox/Body"), "CardBox", "跳过 .. 取第一段")
	assert_eq(AssetLightmapStage._key_of_path("../CardBox"), "CardBox", "只有一段时取它")
	assert_eq(AssetLightmapStage._key_of_path("CardBox/Body"), "CardBox", "没有 .. 前缀也成立")
	assert_eq(AssetLightmapStage._key_of_path(""), "", "空路径返回空键")


func test_resource_key_and_region_area() -> void:
	var mesh := _mesh([true])
	mesh.resource_name = "NamedMesh"
	assert_eq(AssetLightmapSet.key_of(mesh), "NamedMesh", "无路径时退回资源名")
	assert_eq(AssetLightmapSet.key_of(null), "", "空资源没有键")

	var region := _region()
	assert_true(region.has_area(), "有面积")
	region.uv = Rect2()
	assert_false(region.has_area(), "空矩形视为无面积")


func test_attach_missing_product() -> void:
	assert_true(AssetLightmapSet.attach("res://Scenes/NoSuchScene.tscn") == null, "没有产物时返回 null")
	assert_true(AssetLightmapSet.attach("") == null, "空路径返回 null")
	assert_true(AssetLightmapSet.current == null, "不动 current")


## ---- 逐面可叠加判定 ----

func test_can_bake_needs_at_least_one_surface() -> void:
	assert_false(AssetLightmapBinder.can_bake(null), "空网格不可烘")
	assert_false(AssetLightmapBinder.can_bake(ArrayMesh.new()), "无面不可烘")
	assert_true(AssetLightmapBinder.can_bake(_mesh([true])), "有 UV2 的面可烘")
	assert_false(AssetLightmapBinder.can_bake(_mesh([false])), "缺 UV2 不可烘")
	assert_true(AssetLightmapBinder.can_bake(_mesh([false, true])), "任何一面可用即整体可烘")


func test_apply_skips_only_bad_surface() -> void:
	var mi := _instance(_mesh([true, false]))
	assert_true(AssetLightmapBinder.apply(mi, _region(), _atlas()), "有一面可叠即算挂光成功")
	assert_true(mi.get_surface_override_material(0) != null, "有 UV2 的面应挂上宿主材质")
	assert_true(mi.get_surface_override_material(1) == null, "缺 UV2 的面应保持原样")
	mi.free()


func test_apply_fails_without_mask() -> void:
	var mi := _instance(_mesh([false]))
	assert_false(AssetLightmapBinder.apply(mi, _region(), _atlas()), "全都没有 UV2 时不挂光")
	assert_true(mi.get_surface_override_material(0) == null, "不应留下 override")
	mi.free()


## ---- 摘光还原 ----

func test_clear_removes_binder_override() -> void:
	var mi := _instance(_mesh([true]))
	AssetLightmapBinder.apply(mi, _region(), _atlas())
	assert_true(mi.get_surface_override_material(0) != null, "先确认已挂上")
	AssetLightmapBinder.clear(mi)
	assert_true(mi.get_surface_override_material(0) == null, "原本没有 override 就应还原为空")
	mi.free()


func test_clear_restores_business_override() -> void:
	var mi := _instance(_mesh([true]))
	var own := StandardMaterial3D.new()
	mi.set_surface_override_material(0, own)
	AssetLightmapBinder.apply(mi, _region(), _atlas())
	assert_true(mi.get_surface_override_material(0) != own, "挂光时换成带 next_pass 的副本")
	AssetLightmapBinder.clear(mi)
	assert_true(mi.get_surface_override_material(0) == own, "摘光后必须还给业务自设的那份材质")
	mi.free()


func test_clear_restores_material_override() -> void:
	var mi := _instance(_mesh([true]))
	var own := StandardMaterial3D.new()
	mi.material_override = own
	AssetLightmapBinder.apply(mi, _region(), _atlas())
	assert_true(mi.material_override != own, "material_override 也会被换成副本")
	AssetLightmapBinder.clear(mi)
	assert_true(mi.material_override == own, "摘光后还原 material_override")
	mi.free()


## ---- 副本缓存与回收 ----

func test_pairs_shared_per_light_and_base() -> void:
	var mesh := _mesh([true])
	var mat := StandardMaterial3D.new()
	mesh.surface_set_material(0, mat)
	var light := _region()
	var atlas := _atlas()

	var a := _instance(mesh)
	var b := _instance(mesh)
	AssetLightmapBinder.apply(a, light, atlas)
	AssetLightmapBinder.apply(b, light, atlas)
	assert_eq(AssetLightmapBinder._pairs.size(), 1, "同光照 + 同基材质只复制一份")
	assert_true(a.get_surface_override_material(0) == b.get_surface_override_material(0), "两个实例共用同一份宿主材质")

	## 重复 apply 不应叠出第二层
	var host := a.get_surface_override_material(0) as Material
	AssetLightmapBinder.apply(a, light, atlas)
	assert_true(a.get_surface_override_material(0) == host, "重复挂光应幂等")
	assert_true(host.next_pass is ShaderMaterial, "宿主挂着 SH 叠加层")
	a.free()
	b.free()


func test_release_drops_pairs_of_that_light() -> void:
	var light := _region()
	var mi := _instance(_mesh([true]))
	AssetLightmapBinder.apply(mi, light, _atlas())
	assert_eq(AssetLightmapBinder._pairs.size(), 1, "先有一份副本")
	AssetLightmapBinder.release(light)
	assert_eq(AssetLightmapBinder._pairs.size(), 0, "换库时按光照回收副本")
	mi.free()


func test_strength_reaches_mounted_pass() -> void:
	var light := _region()
	var mi := _instance(_mesh([true]))
	AssetLightmapBinder.apply(mi, light, _atlas())
	var sm := (mi.get_surface_override_material(0) as Material).next_pass as ShaderMaterial
	var before := float(sm.get_shader_parameter(&"strength"))
	AssetLightmapBinder.set_strength(0.7)
	var after := float(sm.get_shader_parameter(&"strength"))
	assert_true(after > before, "调亮度应立刻作用到已挂的材质")
	assert_true(absf(after - 0.7) < 0.001, "参数值应等于设定值")
	mi.free()


## ---- 绑定入口 ----

func test_bind_without_region_clears_previous_light() -> void:
	var mesh := _mesh([true])
	mesh.resource_name = "CardBox"
	var mi := _instance(mesh)
	AssetLightmapBinder.apply(mi, _region(), _atlas())
	assert_true(mi.get_surface_override_material(0) != null, "先挂上一份光")

	var other := _instance(_mesh([true]))
	var lib := AssetLightmapSet.new()
	assert_false(lib.bind(other), "库里没有这份网格的光照时返回 false")
	assert_true(other.get_surface_override_material(0) == null, "没有数据时必须擦干净")

	## 运行时网格没有 resource_path，靠 resource_name 反查（与烘焙舞台同一套键规则）
	var region := _region()
	lib.regions["CardBox"] = region
	assert_true(lib.region_of(mesh) == region, "无路径的网格应按 resource_name 命中")
	mi.free()
	other.free()
