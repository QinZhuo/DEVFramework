@tool
class_name DockPropsGen
extends PropGen
## 用例五道具 —— 码头杂物一组：齿轮组 / 活塞连杆 / 多节机械臂 / 工具箱 / 煤堆 / 灯笼
##
## ## 为什么六样挤在一个 [PropGen] 里
## 与用例二的杂物组同理：它们之间**有构图关系**（齿轮带动活塞、机械臂伸向工具箱、
## 灯笼挂在煤堆旁），拆成六个单体后这套关系归摆放层管 —— 而摆放层只按半径/角度撒点，
## 六件会各奔东西，画面上就是"六个孤立的小铁块"。
##
## ## 齿轮怎么做
## 8 齿扁棱柱：一个 [method SdfTool.sd_prism]（n=8）作轮体，
## 再绕圈摆 8 个小方块作齿。两个齿轮一大一小、圆心距 = 两半径之和 − 0.08，
## 于是它们的齿**互相咬进对方** —— 啮合关系是几何，不是摆位巧合。

const GEAR_A := Vector3(-0.62, 0.42, 0.30)   ## 大齿轮中心（竖直面朝 Z）
const GEAR_B := Vector3(-0.10, 0.30, 0.30)   ## 小齿轮中心
const RA := 0.42
const RB := 0.26
const CYL_C := Vector3(0.55, 0.30, -0.30)    ## 活塞缸体中心
const ARM_BASE := Vector3(1.05, 0.0, 0.35)   ## 机械臂底座
const TOOL_C := Vector3(-1.00, 0.0, -0.45)
const COAL_C := Vector3(0.30, 0.0, 0.80)
const LAMP_C := Vector3(-0.30, 0.0, -1.00)

## 机械臂朝左还是朝右。本组会被用两次（两组落在不同角度），
## 形状完全一致的话画面上就是"同一件道具复制了两份" ——
## 而同一种机械臂本来就该有左右手的装法，这不是敷衍，是避免重复感的最低成本做法。
var _flip := 1.0

func prepare() -> void:
	_flip = -1.0 if rng.randi_range(0, 1) == 0 else 1.0

## 一个齿轮：轮体（8 棱柱）+ 齿（8 个小方块绕圈）
func _gear(p: Vector3, c: Vector3, r: float) -> float:
	## 竖着朝 Z ⇒ 把 (x, y) 当轮平面、z 当厚度：置换成 (p.x, p.y, p.z)
	var q := Vector3(p.x - c.x, p.y - c.y, p.z - c.z)
	var d := SdfTool.sd_prism(q, r * 0.82, 0.07, 8)
	for i in 8:
		var a := TAU * float(i) / 8.0
		d = SdfTool.op_union(d, SdfTool.sd_box(
			q - Vector3(cos(a) * r, sin(a) * r, 0.0), Vector3(0.09, 0.09, 0.09)))
	return d

func _piston(p: Vector3) -> float:
	var d := SdfTool.sd_cylinder(p - Vector3(CYL_C.x, 0.34, CYL_C.z), 0.34, 0.20)
	## 活塞杆：从缸顶斜伸出去（sd_segment 支持任意走向）
	d = SdfTool.op_union(d, SdfTool.sd_segment(p,
		Vector3(CYL_C.x, 0.66, CYL_C.z), Vector3(CYL_C.x + 0.10, 0.86, CYL_C.z - 0.34), 0.05))
	## 连杆末端一个环（轴沿 X ⇒ 置换）
	var q := Vector3(p.y - 0.86, p.z - (CYL_C.z - 0.34), p.x - (CYL_C.x + 0.10))
	d = SdfTool.op_union(d, SdfTool.sd_torus(q, 0.12, 0.035))
	return d

## 多节机械臂：底座 + 下臂 + 肘 + 上臂 + 夹爪（两片）
##
## [member _flip] 让整条臂沿 X 镜像：底座、肘、腕的 x 偏移全部取反，
## 于是同一份几何能装出"左手"与"右手"两种形态。
func _arm(p: Vector3) -> float:
	var f := _flip
	var bx := ARM_BASE.x * f
	var d := SdfTool.sd_cylinder(p - Vector3(bx, 0.10, ARM_BASE.z), 0.10, 0.26)
	d = SdfTool.op_union(d, SdfTool.sd_sphere(p - Vector3(bx, 0.36, ARM_BASE.z), 0.16))
	var elbow := Vector3(bx - 0.10 * f, 0.92, ARM_BASE.z + 0.30)
	d = SdfTool.op_union(d, SdfTool.sd_segment(p,
		Vector3(bx, 0.36, ARM_BASE.z), elbow, 0.09))
	d = SdfTool.op_union(d, SdfTool.sd_sphere(p - elbow, 0.13))
	var hand := Vector3(bx + 0.28 * f, 1.34, ARM_BASE.z + 0.52)
	d = SdfTool.op_union(d, SdfTool.sd_segment(p, elbow, hand, 0.075))
	for s in [-1.0, 1.0]:
		d = SdfTool.op_union(d, SdfTool.sd_segment(p, hand,
			hand + Vector3(s * 0.10, 0.16, 0.10), 0.04))
	return d

func _toolbox(p: Vector3) -> float:
	var c := p - TOOL_C
	var d := SdfTool.sd_box(c - Vector3(0.0, 0.24, 0.0), Vector3(0.36, 0.24, 0.24))
	## 盖子：一圈外伸的檐
	d = SdfTool.op_union(d, SdfTool.sd_box(
		c - Vector3(0.0, 0.50, 0.0), Vector3(0.40, 0.04, 0.28)))
	## 提手：一道细梁
	d = SdfTool.op_union(d, SdfTool.sd_box(
		c - Vector3(0.0, 0.60, 0.0), Vector3(0.16, 0.05, 0.03)))
	return d

## 煤堆：三个不同大小的半球叠在一起（用 sd_sphere 下压地面以下）
func _coal(p: Vector3) -> float:
	var c := p - COAL_C
	var d := SdfTool.sd_sphere(c - Vector3(0.0, 0.10, 0.0), 0.30)
	d = SdfTool.op_union(d, SdfTool.sd_sphere(c - Vector3(0.26, 0.06, 0.14), 0.22))
	d = SdfTool.op_union(d, SdfTool.sd_sphere(c - Vector3(-0.22, 0.05, -0.12), 0.20))
	return d

## 灯笼：柱 + 灯罩（上小下大的圆台）+ 提环
func _lamp(p: Vector3) -> float:
	var c := p - LAMP_C
	var d := SdfTool.sd_cylinder(c - Vector3(0.0, 0.62, 0.0), 0.62, 0.055)
	d = SdfTool.op_union(d, SdfTool.sd_capped_cone(
		c - Vector3(0.0, 0.36, 0.0), 0.16, 0.13, 0.20))
	d = SdfTool.op_union(d, SdfTool.sd_cylinder(
		c - Vector3(0.0, 0.18, 0.0), 0.06, 0.24))
	d = SdfTool.op_union(d, SdfTool.sd_torus(c - Vector3(0.0, 1.28, 0.0), 0.09, 0.025))
	return d

func local_bounds() -> AABB:
	return AABB(Vector3(-1.45, 0.0, -1.35), Vector3(2.90, 1.60, 2.40))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		var d := _gear(p, GEAR_A, RA)
		d = SdfTool.op_union(d, _gear(p, GEAR_B, RB))
		d = SdfTool.op_union(d, _piston(p))
		d = SdfTool.op_union(d, _arm(p))
		d = SdfTool.op_union(d, _toolbox(p))
		d = SdfTool.op_union(d, _coal(p))
		d = SdfTool.op_union(d, _lamp(p))
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	return [
		## ① 灯笼里的火光（灯罩内的一小团暖黄）
		SteamSkin.box(LAMP_C + Vector3(0.0, 0.36, 0.0),
			Vector3(0.30, 0.32, 0.30), SteamSkin.LAMP),
		## ② 煤堆
		SteamSkin.box(COAL_C + Vector3(0.0, 0.14, 0.0),
			Vector3(1.10, 0.40, 1.00), SteamSkin.COAL),
		## ③ 工具箱（深棕木）
		SteamSkin.box(TOOL_C + Vector3(0.0, 0.32, 0.0),
			Vector3(0.82, 0.68, 0.60), SteamSkin.WOOD),
		## ④ 机械臂（做旧铁）—— 包围盒跟着 [member _flip] 一起镜像
		SteamSkin.box(Vector3(ARM_BASE.x * _flip + 0.10 * _flip, 0.80, ARM_BASE.z + 0.40),
			Vector3(0.90, 1.60, 0.90), SteamSkin.IRON),
		## ⑤ 两个齿轮（暗铜）
		SteamSkin.box(GEAR_A, Vector3(RA * 2.2, RA * 2.2, 0.22), SteamSkin.BRASS_DK),
		SteamSkin.box(GEAR_B, Vector3(RB * 2.2, RB * 2.2, 0.22), SteamSkin.BRASS_DK),
		## ⑥ 兜底：活塞与缸体（黄铜）
		SteamSkin.all(b, SteamSkin.BRASS),
	]

func meta() -> Dictionary:
	return {
		&"tag": "dock_props",
		&"surface_snap": true,
		&"wants_ground": true,
	}
