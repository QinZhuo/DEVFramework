@tool
class_name PropGenDef extends Def
## 单体物体烘焙参数 —— 所有单体生成器（PropGen）共用的"怎么把 SDF 变成网格"
##
## 这里**只有精度 / 算法 / 画风，没有任何内容语义**：
## - "商店该多大、门朝哪" → 项目层的具体生成器
## - "用 12cm 体素、NETS、硬边化" → 框架层，也就是本文件
##
## 分层红线见 PropGen.gd 顶部说明。

## 体素边长（米）。越小越精细也越慢：
## 0.08~0.15 适合建筑类，0.04~0.06 适合载具 / 道具类
@export_range(0.02, 0.5, 0.01) var voxel_size := 0.12

## 等值面算法：SURFACE_NETS 曲面均匀成本低 / DUAL_CONTOURING 保棱角（三渲二首选）
@export var algo: MeshExtractor.Algo = MeshExtractor.Algo.SURFACE_NETS

## DC 的 QEF 正则项（缓解平面 / 线状单元的奇异）
@export_range(0.001, 0.5, 0.001) var dc_eps := 0.05

## 主平面特征法线：三渲二硬边的关键。关闭则退回梯度法线，棱角会被圆化
@export var sharp_normal := true

## 硬边化量化步长（米）—— 画风开关：
## 0 = 关闭（光滑） / 0.15 = 棱面化 / 0.4 = 低多边形
@export_range(0.0, 1.0, 0.01) var sharpen := 0.0

## 场边界余量（米）：物体几何贴到 bounds 边缘时留出安全距离，
## 否则等值面会被场边界截断（缺面）
@export_range(0.0, 2.0, 0.05) var margin := 0.4

## ============================ 双产物 ============================
## 一次烘焙同时给出**低多边形网格**与**体素网格**，两者共用同一个场 ——
## 这是"一份数据两种用途"成立的成本前提：烘焙占总耗时 99.9% 以上，
## 两个提取步骤相对它都很便宜，所以绝不该为第二种用途再烘一遍。
##
## 由此得到的使用方式：同一个 [PropGen]、同一个 seed，
## 要 lowpoly 场景就取 `mesh`，要体素风就取 `voxel`，几何完全同源、必然一致。

## 体素产物最长边分辨率。<=0 = 不产体素（只要低多边形网格）。
## 参考量级：48~64 适合微缩模型，96+ 才看得出细节。
@export_range(0, 256, 1) var voxel_res := 0

## 体素方块的**物理边长**（米）。> 0 时压过 [member voxel_res]。
##
## 为什么要单独一个字段：res 是"最长边切几格"，实际边长 = 窄带盒最长边 / res，
## 而窄带盒比模型宽出约 2×band（默认 3×voxel_size）。同一场景里模型尺寸差几倍时，
## 这个余量带来的误差也跟着差几倍 —— 实测 7.9 米的大楼偏大 9%，1.16 米的长椅偏大 66%，
## 于是"统一方块"不成立，而所有中间数字看起来都正常。
## 要让全场方块一样大，就直接说边长是多少米。
@export_range(0.0, 1.0, 0.005, "or_greater") var voxel_cell := 0.0

## 体素调色板。为空则用提取器默认色（几何仍然正确，只是没有分件色）。
## 建议直接给场景风格包里的 [ToonPaletteDef]，让体素与网格同属一套配色。
@export var voxel_palette: ToonPaletteDef = null

## 按局部包围盒开一块恰好够用的场（原点在局部原点，可含负坐标块）
func make_field(bounds: AABB) -> SdfField:
	var f := SdfField.create(32, voxel_size, Vector3.ZERO, -1.0)
	var g := Vector3.ONE * margin
	SdfTool.allocate_cells(f, _cells_lo(bounds.position - g), _cells_hi(bounds.end + g))
	return f

func _cells_lo(p: Vector3) -> Vector3i:
	var vs := voxel_size
	return Vector3i(floori(p.x / vs) - 1, floori(p.y / vs) - 1, floori(p.z / vs) - 1)

func _cells_hi(p: Vector3) -> Vector3i:
	var vs := voxel_size
	return Vector3i(ceili(p.x / vs) + 1, ceili(p.y / vs) + 1, ceili(p.z / vs) + 1)

func get_desc(_data) -> String:
	return "%s @%.2fm%s" % [
		"DualContouring" if algo == MeshExtractor.Algo.DUAL_CONTOURING else "SurfaceNets",
		voxel_size,
		" sharp%.2f" % sharpen if sharpen > 0.0 else "",
	]

func _to_string() -> String:
	return name
