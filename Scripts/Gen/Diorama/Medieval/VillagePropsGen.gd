@tool
class_name VillagePropsGen
extends PropGen
## 用例二道具 —— 广场杂物一组：篝火 / 木箱堆 / 手推车 / 路牌
##
## ## 为什么四样挤在一个 [PropGen] 里
## 这四样是"一组生活痕迹"，它们之间**有构图关系**（火在中间、车停在箱旁、
## 路牌立在路口），分开成四个单体后这套关系归谁管？答案是没人管 ——
## 摆放层只知道按半径/角度撒点，四件会各奔东西，画面上就是"四个孤立的小物件"。
## 关系属于几何，所以写在同一件里，由本文件的局部偏移固定下来。
##
## ## 轮子怎么躺的
## [method SdfTool.sd_torus] 的环平面是 XY、轴沿 Z。要一个**立式车轮**（轴沿 X），
## 交换一下分量即可：`q = (p.y, p.z, p.x)`。这是纯坐标置换，
## 不需要任何旋转矩阵，也就不会引入"非轴对齐面"这种体素处理不了的东西。

const FIRE_C := Vector3(-0.85, 0.0, 0.42)   ## 篝火中心
const CRATE_C := Vector3(0.72, 0.0, 0.50)   ## 木箱堆
const CART_C := Vector3(0.10, 0.0, -0.62)   ## 手推车
const SIGN_C := Vector3(1.30, 0.0, -0.30)   ## 路牌

func _fire(p: Vector3) -> float:
	var f := p - FIRE_C
	var d := 1e9
	## 一圈石块：6 个小棱柱绕火堆
	for i in 6:
		var a := TAU * float(i) / 6.0
		d = SdfTool.op_union(d, SdfTool.sd_prism(
			f - Vector3(cos(a) * 0.34, 0.07, sin(a) * 0.34), 0.11, 0.07, 6))
	## 柴堆：两根交叉的方柱（只用轴对齐，交叉靠两个不同朝向的盒子叠出来）
	d = SdfTool.op_union(d, SdfTool.sd_box(
		f - Vector3(0.0, 0.14, 0.0), Vector3(0.30, 0.05, 0.07)))
	d = SdfTool.op_union(d, SdfTool.sd_box(
		f - Vector3(0.0, 0.14, 0.0), Vector3(0.07, 0.05, 0.30)))
	## 火苗：三级阶梯锥
	var y := 0.19
	var hw := 0.19
	for i in 3:
		d = SdfTool.op_union(d, SdfTool.sd_box(
			f - Vector3(0.0, y, 0.0), Vector3(hw, 0.07, hw)))
		y += 0.15
		hw = maxf(hw - 0.05, 0.07)
	return d

func _crates(p: Vector3) -> float:
	var c := p - CRATE_C
	var d := SdfTool.sd_box(c - Vector3(0.0, 0.28, 0.0), Vector3(0.28, 0.28, 0.28))
	d = SdfTool.op_union(d, SdfTool.sd_box(
		c - Vector3(0.34, 0.20, 0.10), Vector3(0.20, 0.20, 0.20)))
	d = SdfTool.op_union(d, SdfTool.sd_box(
		c - Vector3(-0.10, 0.74, 0.06), Vector3(0.22, 0.18, 0.22)))
	return d

func _cart(p: Vector3) -> float:
	var c := p - CART_C
	var d := 1e9
	## 车斗：四面板围出的斗（外盒减内盒）
	var bed := SdfTool.sd_box(c - Vector3(0.0, 0.44, 0.0), Vector3(0.42, 0.22, 0.30))
	bed = SdfTool.op_sub(bed, SdfTool.sd_box(
		c - Vector3(0.0, 0.60, 0.0), Vector3(0.36, 0.16, 0.24)))
	d = SdfTool.op_union(d, bed)
	## 两个立式车轮（轴沿 X）
	for cz in [-0.26, 0.26]:
		d = SdfTool.op_union(d, SdfTool.sd_torus(
			Vector3(c.y - 0.24, c.z - cz, c.x), 0.24, 0.06))
	## 车轴
	d = SdfTool.op_union(d, SdfTool.sd_box(
		c - Vector3(0.0, 0.24, 0.0), Vector3(0.04, 0.04, 0.30)))
	## 车辕：斜着伸出去的一根（用三段阶梯盒近似斜杆，不给斜面）
	for i in 3:
		d = SdfTool.op_union(d, SdfTool.sd_box(
			c - Vector3(0.0, 0.34 + i * 0.06, -0.40 - i * 0.16),
			Vector3(0.05, 0.05, 0.16)))
	return d

func _sign(p: Vector3) -> float:
	var s := p - SIGN_C
	var d := SdfTool.sd_box(s - Vector3(0.0, 0.62, 0.0), Vector3(0.06, 0.62, 0.06))
	d = SdfTool.op_union(d, SdfTool.sd_box(
		s - Vector3(0.16, 1.05, 0.0), Vector3(0.30, 0.13, 0.05)))
	## 柱脚一小堆石，免得柱子像插在地里的针
	d = SdfTool.op_union(d, SdfTool.sd_prism(
		s - Vector3(0.0, 0.05, 0.0), 0.16, 0.05, 6))
	return d

func local_bounds() -> AABB:
	return AABB(Vector3(-1.30, 0.0, -1.05), Vector3(2.90, 1.45, 1.95))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		var d := _fire(p)
		d = SdfTool.op_union(d, _crates(p))
		d = SdfTool.op_union(d, _cart(p))
		d = SdfTool.op_union(d, _sign(p))
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	var out := [
		## ① 火苗（亮橙）—— 全场最亮的一块，也是唯一的暖光源视觉锚
		MedievalSkin.box(FIRE_C + Vector3(0.0, 0.32, 0.0),
			Vector3(0.40, 0.42, 0.40), MedievalSkin.EMBER),
		## ② 柴堆（深木棕）
		MedievalSkin.box(FIRE_C + Vector3(0.0, 0.14, 0.0),
			Vector3(0.62, 0.12, 0.62), MedievalSkin.WOOD),
		## ③ 路牌板（浅木黄）
		MedievalSkin.box(SIGN_C + Vector3(0.16, 1.05, 0.0),
			Vector3(0.60, 0.26, 0.10), MedievalSkin.WOOD_LT),
	]
	## ④ 两个车轮（深灰铁）
	for cz in [-0.26, 0.26]:
		out.append(MedievalSkin.box(CART_C + Vector3(0.0, 0.24, cz),
			Vector3(0.14, 0.52, 0.14), MedievalSkin.METAL))
	## ⑤ 兜底：木箱 / 车斗 / 石圈统一落深木 —— 这三样混着岩灰也说得通
	out.append(MedievalSkin.all(b, MedievalSkin.WOOD))
	return out

func meta() -> Dictionary:
	return {
		&"tag": "props",
		&"surface_snap": true,
		&"wants_ground": true,
	}
