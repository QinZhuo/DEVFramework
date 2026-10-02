@tool
class_name PropBuild extends RefCounted
## 单体构建结果 —— **纯局部空间**，不含位置、不含旋转、不含世界引用
##
## 这是"独立物体生成器"这一层能独立存在的关键：
## 一个商店的 PropBuild 烘焙出来后，无论放在地球哪边，网格数据完全相同，
## 所以世界存档只需要记 "seed=1234 放在 (120, 0, -45) 偏转 90°"，
## 流式加载时按需重烘焙即可，不必存网格。
##
## 对照 PropLayoutTool.Placement —— 那才带 Transform3D，是布局层的产物。

var mesh: SdfMesh                    ## 局部坐标网格（原点 = 生成器自定的局部原点）
var voxel: SdfVoxel                     ## 体素网格产物（可选）。与 mesh **同源**：两者共用同一次场烘焙
var bounds := AABB()                  ## 局部包围盒
var footprint := Vector2.ZERO         ## 逻辑占地（XZ，米）。可小于几何外接，供避让用
var meta := {}                        ## 生成器自报的属性（tag / 门朝向 / 是否可贴地 …）

func is_empty() -> bool:
	return mesh == null or mesh.is_empty()

## 是否带了体素产物。注意它**不代表**有网格：
## 体素网格同样可以独立成立（纯体素风模型），此时 [method is_empty] 为真。
func has_voxel() -> bool:
	return voxel != null and not voxel.is_empty()

func vertex_count() -> int:
	return mesh.vertex_count() if mesh else 0

func triangle_count() -> int:
	return mesh.triangle_count() if mesh else 0

## 避让用的外接圆半径（XZ 平面）
func collision_radius() -> float:
	return footprint.length() * 0.5

## 输出形态 —— 决定 [method to_mesh_instance] 用哪一份产物出网格。
##
## [b]为什么需要显式指定[/b]：体素产物此前没有任何渲染入口，
## 而 [method is_empty] 只看网格，于是"纯体素模型"（网格空、体素有）
## 会安静地渲染成空节点 —— 不报错、不进日志，只是画面上什么都没有。
## 双投影要能被比较、要能被单独出图，就必须能显式点选投影形态。
enum Form {
	AUTO,         ## 有网格走网格；网格空而体素非空时退回体素（修掉"纯体素渲染成空"）
	MESH,         ## 强制光滑等值面网格
	VOXEL_GREEDY, ## 强制体素·贪心合并：体素模型的常规输出（面数低）
	VOXEL_ITEM,   ## 强制体素·逐块方块：Minecraft / MagicaVoxel 观感，
	              ## 也是验证"体素一致性"的基准形态 —— 每个方块独立可辨
}

## 生成资源节点（局部变换，父节点负责摆到世界里）
##
## [param material] 故意用 [Variant] 而非 [Material]，它可以是两种东西：
## · [Material] —— 单材质。体素形态下所有调色板索引都用它（历史行为）。
## · [Callable] —— `func(palette_index: int, face_dir: int) -> Material`，
##   逐索引取色。这是让 [method PropGen.voxel_regions] 声明的部位分色**真正显示出来**
##   的唯一出口：索引怎么算由提取器管，索引 → 材质由调用方管。
##
## [param form] 见 [enum Form]。默认 [constant Form.AUTO] 保持历史行为（走网格），
## 但网格为空而体素非空时会自动退回贪心体素。
func to_mesh_instance(material: Variant = null, form: Form = Form.AUTO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	var want := form
	if want == Form.AUTO:
		want = Form.MESH if not is_empty() \
			else (Form.VOXEL_GREEDY if has_voxel() else Form.MESH)
	## 网格形态只认单个 Material：调用方传了 Callable 时按"无材质"处理，
	## 而不是把 Callable 塞给 to_arraymesh（那是 Variant→Material 的隐式转换，会炸）。
	var flat: Material = material if material is Material else null
	match want:
		Form.VOXEL_GREEDY, Form.VOXEL_ITEM:
			if not has_voxel():
				push_warning("[PropBuild] 强制体素形态但体素产物为空（voxel_res 太小？"\
				+ "形状与分辨率不匹配时会静默退化）→ 回退网格")
				if not is_empty():
					mi.mesh = mesh.to_arraymesh(flat)
				return mi
			## 材质在体素侧是"按调色板索引逐索引取"的 Callable，不是单个材质。
			var provider := Callable()
			if material is Callable:
				provider = material
			elif flat != null:
				provider = func(_pi: int, _face_dir: int) -> Material:
					return flat
			mi.mesh = voxel.to_greedy_mesh(provider) if want == Form.VOXEL_GREEDY \
				else voxel.to_item_mesh(provider)
			mi.name = "Voxel"
		_:
			if not is_empty():
				mi.mesh = mesh.to_arraymesh(flat)
	return mi

## 旋转 yaw 后的占地半尺寸向量（用于贴地采样与分离）
func rotated_extent(yaw: float) -> Vector2:
	var c := absf(cos(yaw))
	var s := absf(sin(yaw))
	return Vector2(
		footprint.x * c + footprint.y * s,
		footprint.x * s + footprint.y * c) * 0.5
