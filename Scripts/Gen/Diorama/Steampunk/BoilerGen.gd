@tool
class_name BoilerGen
extends PropGen
## 用例五环境 —— 立式蒸汽锅炉：主筒 + 炉门火光 + 压力表 + 铜管 + 安全阀 + 蒸汽口
##
## ## 为什么筒体用圆柱而不用棱柱
## 用例五的验收项里没有"统一体素"，反倒写着"高细节 AAA 资产"。
## 锅炉是这套里最该有"工业曲面"的东西：一个八棱的锅炉一眼是饲料槽。
## 于是这里用 [method SdfTool.sd_cylinder]（轴沿 Y）—— 体素阶梯在 0.14 的
## 格子上已经细到读作"圆"，这正是"高细节"该有的样子。
##
## ## 压力表朝 +Z（镜头侧）
## 表盘用 [method SdfTool.sd_torus] 且**不做分量置换**：torus 的环平面是 XY、
## 轴沿 Z，正好就是"竖着朝 +Z 的一块圆表盘"。省一次置换，也少一处出错的机会。
##
## ## 炉门为什么是"凹进去再嵌一片亮面"
## 炉膛的火光是全场唯一的暖光源叙事点。做成凸出的一块橙色方块，
## 在 0.14 的体素下就是"锅炉上贴了块橙贴纸"；凹进 0.08 米再嵌亮面，
## 四周的铸铁会投下一圈阴影，火才像是从里面透出来的。

const R := 0.55          ## 主筒半径
const H := 0.78          ## 主筒半高
const CY := 0.82         ## 主筒中心高度
const DOOR_Y := 0.55     ## 炉门中心高度
const DOOR_Z := 0.52     ## 炉门所在的前表面（+Z）
const GAUGE_Y := 1.30    ## 压力表中心高度
const STEAM_Y := 1.72    ## 蒸汽口高度

func local_bounds() -> AABB:
	return AABB(Vector3(-0.95, 0.0, -0.95), Vector3(1.90, 2.05, 1.90))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		## 主筒 + 上下两道加厚箍
		var d := SdfTool.sd_cylinder(p - Vector3(0.0, CY, 0.0), H, R)
		for y in [CY - H + 0.10, CY + H - 0.10]:
			d = SdfTool.op_union(d, SdfTool.sd_cylinder(
				p - Vector3(0.0, y, 0.0), 0.07, R + 0.05))
		## 顶盖：一圈外伸的檐 + 中央蒸汽口
		d = SdfTool.op_union(d, SdfTool.sd_cylinder(
			p - Vector3(0.0, CY + H + 0.04, 0.0), 0.05, R + 0.10))
		d = SdfTool.op_union(d, SdfTool.sd_cylinder(
			p - Vector3(0.0, STEAM_Y, 0.0), 0.16, 0.13))
		## 底座：一圈比筒身宽的铁裙
		d = SdfTool.op_union(d, SdfTool.sd_cylinder(
			p - Vector3(0.0, 0.09, 0.0), 0.09, R + 0.14))
		## 炉门：外框凸出，门洞凹进
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, DOOR_Y, DOOR_Z), Vector3(0.30, 0.28, 0.05)))
		d = SdfTool.op_sub(d, SdfTool.sd_box(
			p - Vector3(0.0, DOOR_Y, DOOR_Z + 0.02), Vector3(0.22, 0.20, 0.10)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, DOOR_Y, DOOR_Z - 0.03), Vector3(0.20, 0.18, 0.05)))
		## 压力表：表盘 + 一小段接管
		d = SdfTool.op_union(d, SdfTool.sd_torus(
			p - Vector3(0.0, GAUGE_Y, 0.44), 0.20, 0.06))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, GAUGE_Y, 0.30), Vector3(0.05, 0.05, 0.16)))
		## 铜管：从筒侧绕到顶盖（两段折线）
		d = SdfTool.op_union(d, SdfTool.sd_segment(p,
			Vector3(-0.52, 1.05, 0.20), Vector3(-0.72, 1.05, 0.52), 0.06))
		d = SdfTool.op_union(d, SdfTool.sd_segment(p,
			Vector3(-0.72, 1.05, 0.52), Vector3(-0.72, 1.66, 0.52), 0.06))
		d = SdfTool.op_union(d, SdfTool.sd_segment(p,
			Vector3(-0.72, 1.66, 0.52), Vector3(-0.34, 1.66, 0.30), 0.06))
		## 安全阀：小球 + 细柱
		d = SdfTool.op_union(d, SdfTool.sd_cylinder(
			p - Vector3(0.42, 1.62, -0.18), 0.14, 0.07))
		d = SdfTool.op_union(d, SdfTool.sd_sphere(
			p - Vector3(0.42, 1.80, -0.18), 0.13))
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	return [
		## ① 炉门里的火光（凹在门洞里的一小片）
		SteamSkin.box(Vector3(0.0, DOOR_Y, DOOR_Z - 0.02),
			Vector3(0.40, 0.36, 0.10), SteamSkin.EMBER),
		## ② 蒸汽口：顶部一小团白
		SteamSkin.box(Vector3(0.0, STEAM_Y + 0.12, 0.0),
			Vector3(0.34, 0.34, 0.34), SteamSkin.STEAM),
		## ③ 压力表表盘（玻璃）与指针盘（仪表白）
		SteamSkin.box(Vector3(0.0, GAUGE_Y, 0.44),
			Vector3(0.42, 0.42, 0.16), SteamSkin.GLASS),
		## ④ 铜管（紫铜）
		SteamSkin.box(Vector3(-0.62, 1.35, 0.42),
			Vector3(0.40, 0.80, 0.40), SteamSkin.COPPER),
		## ⑤ 安全阀（暗铜）
		SteamSkin.box(Vector3(0.42, 1.72, -0.18),
			Vector3(0.30, 0.42, 0.30), SteamSkin.BRASS_DK),
		## ⑥ 兜底：筒体黄铜
		SteamSkin.all(b, SteamSkin.BRASS),
	]

func meta() -> Dictionary:
	return {
		&"tag": "boiler",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(0, 0, 1),
	}
