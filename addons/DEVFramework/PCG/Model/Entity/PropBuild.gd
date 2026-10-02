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

## 生成资源节点（局部变换，父节点负责摆到世界里）
func to_mesh_instance(material: Material = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	if not is_empty():
		mi.mesh = mesh.to_arraymesh(material)
	mi.name = "Mesh"
	return mi

## 旋转 yaw 后的占地半尺寸向量（用于贴地采样与分离）
func rotated_extent(yaw: float) -> Vector2:
	var c := absf(cos(yaw))
	var s := absf(sin(yaw))
	return Vector2(
		footprint.x * c + footprint.y * s,
		footprint.x * s + footprint.y * c) * 0.5
