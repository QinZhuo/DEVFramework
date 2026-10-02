@tool
class_name BakeryShopGen
extends PropGen
## 用例四主体 —— 三层街角面包店（全盒体，无平滑曲面）
##
## ============================ 造型的三条自律 ============================
## 1. **只用 [method SdfTool.sd_box]**。用例四的验收项写着"有无平滑曲面或非体素斜角"，
##    而体素提取器会把任何非轴对齐的表面切成阶梯 —— 也就是说斜角会变成"阶梯的斜角"，
##    既不是体素也不是斜面，是两者都不像的东西。所以这里一个圆柱都不用。
## 2. **阶梯靠"层"不靠"倒角"**。屋檐、屋顶、遮阳棚都是一叠逐层缩放的扁盒，
##    每层厚度相同、逐层内收 —— 这正是 stair-stepped edges 的字面实现。
## 3. **楼层分隔靠退线**。二三层比一层窄 [constant INSET]，
##    于是楼与楼之间自带一道投影阴影线，不需要额外贴一条腰线。
##
## 分色由 [method voxel_regions] 声明，索引见 [VoxelSkin]。

const INSET := 0.15      ## 二三层相对一层每边内收
const FRONT := 1.5       ## 一层正面 z（+Z 为正面）
const H1 := 2.6          ## 一层层高
const H2 := 2.4          ## 二层
const H3 := 2.2          ## 三层

## 窗洞 / 发光面的半尺寸。实际给到 2×4 格（0.32×0.64 米）。
## 严格 1×2 在 0.16 的格子下只有 16×32 厘米，在 8 米见方的底座上几乎看不见，
## 而"窗户"恰恰是判断这是店铺的关键特征 —— 尺寸是按可读性定的，不是按字面。
const WIN := Vector2(0.20, 0.36)
const PANE := Vector2(0.16, 0.32)

## 门窗位置。放在 [method prepare] 里算一次，[method build] 与
## [method voxel_regions] 共用，避免两处各写一份坐标。
var _wins: Array = []

## 每层的墙：中心 + 半尺寸。半宽逐层收 INSET。
func _walls() -> Array:
	return [
		[Vector3(0.0, H1 * 0.5, 0.0), Vector3(1.6, H1 * 0.5, FRONT)],
		[Vector3(0.0, H1 + H2 * 0.5, 0.0),
			Vector3(1.6 - INSET, H2 * 0.5, FRONT - INSET)],
		[Vector3(0.0, H1 + H2 + H3 * 0.5, 0.0),
			Vector3(1.6 - INSET, H3 * 0.5, FRONT - INSET)],
	]

## 三道屋檐：挑出量逐层减少，把"三层"这件事在剪影上说清楚。
func _eaves() -> Array:
	return [
		[Vector3(0.0, H1, 0.0), Vector3(1.6 + 0.18, 0.09, FRONT + 0.18)],
		[Vector3(0.0, H1 + H2, 0.0), Vector3(1.6 + 0.02, 0.09, FRONT + 0.02)],
		[Vector3(0.0, H1 + H2 + H3, 0.0), Vector3(1.6 + 0.02, 0.09, FRONT + 0.02)],
	]

## 屋顶：5 级等厚阶梯，逐级每边收 0.3。
func _roof() -> Array:
	var out := []
	var y := H1 + H2 + H3 + 0.15    ## 起始于最高一道屋檐顶面（7.29）之上
	var hw := 1.6 - INSET
	var hd := FRONT - INSET
	for i in 5:
		out.append([Vector3(0.0, y, 0.0), Vector3(hw, 0.06, hd)])
		y += 0.12
		hw = maxf(hw - 0.3, 0.24)
		hd = maxf(hd - 0.3, 0.20)
	return out

## 遮阳棚：3 级阶梯，每级下移 0.18、外伸 0.30。
func _awning() -> Array:
	var out := []
	var y := 2.10
	var z := FRONT + 0.22
	for i in 3:
		out.append([Vector3(0.0, y, z), Vector3(1.15 - i * 0.10, 0.07, 0.30)])
		y -= 0.18
		z += 0.30
	return out

## 一扇窗 = 挖洞 + 洞里嵌一片发光面。洞比面大，四周留出的墙体就是窗框。
func _win(center: Vector3, depth: float) -> Dictionary:
	return {
		&"cut_c": center,
		&"cut_h": Vector3(WIN.x, WIN.y, depth),
		&"pane_c": Vector3(center.x, center.y, center.z - 0.08),
		&"pane_h": Vector3(PANE.x, PANE.y, 0.06),
	}

func prepare() -> void:
	_wins = [
		## 一层：门两侧各一扇
		_win(Vector3(-1.05, 1.35, FRONT), 0.30),
		_win(Vector3(1.05, 1.35, FRONT), 0.30),
	]
	## 二层：三扇，把"楼层"读成一条水平带
	for x in [-0.90, 0.0, 0.90]:
		_wins.append(_win(Vector3(x, 3.85, FRONT - INSET), 0.26))
	## 三层：两扇
	for x in [-0.70, 0.70]:
		_wins.append(_win(Vector3(x, 6.15, FRONT - INSET), 0.26))

func local_bounds() -> AABB:
	## 含屋檐挑出与遮阳棚外伸（z 到 2.6），否则遮阳棚会被场边界截断
	return AABB(Vector3(-1.78, 0.0, -1.68), Vector3(3.56, 7.9, 4.3))

func build(_field: SdfField) -> void:
	var wins := _wins
	var walls := _walls()
	var eaves := _eaves()
	var roof := _roof()
	var aw := _awning()
	fill_shape(func(p: Vector3) -> float:
		var d := 1e9
		## 三层墙
		for w in walls:
			d = SdfTool.op_union(d, SdfTool.sd_box(p - w[0], w[1]))
		## 三道屋檐
		for e in eaves:
			d = SdfTool.op_union(d, SdfTool.sd_box(p - e[0], e[1]))
		## 五级阶梯屋顶
		for r in roof:
			d = SdfTool.op_union(d, SdfTool.sd_box(p - r[0], r[1]))
		## 遮阳棚 + 两根支柱
		for a in aw:
			d = SdfTool.op_union(d, SdfTool.sd_box(p - a[0], a[1]))
		for sx in [-1.0, 1.0]:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(sx, 0.87, FRONT + 0.80), Vector3(0.06, 0.87, 0.06)))

		## 挖门洞
		d = SdfTool.op_sub(d, SdfTool.sd_box(
			p - Vector3(0.0, 0.95, FRONT), Vector3(0.40, 0.95, 0.30)))
		## 门板：凹进洞里
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 0.90, FRONT - 0.16), Vector3(0.34, 0.90, 0.08)))

		## 门框：左、右、上三根，凸出墙面
		for fx in [-0.52, 0.52]:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(fx, 0.95, FRONT + 0.02), Vector3(0.12, 1.07, 0.14)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 2.02, FRONT + 0.02), Vector3(0.64, 0.12, 0.14)))

		## 窗：先挖洞，再嵌发光面
		for w in wins:
			d = SdfTool.op_sub(d, SdfTool.sd_box(p - w[&"cut_c"], w[&"cut_h"]))
			d = SdfTool.op_union(d, SdfTool.sd_box(p - w[&"pane_c"], w[&"pane_h"]))
		return d)

func voxel_regions() -> Array:
	var out := []
	## 顺序即优先级：首个命中即用（见 VoxelExtractor._tinted）
	## ① 窗发光面
	for w in _wins:
		out.append(VoxelSkin.box(w[&"pane_c"], w[&"pane_h"] * 2.0, VoxelSkin.WINDOW))
	## ② 门框三根
	for fx in [-0.52, 0.52]:
		out.append(VoxelSkin.box(Vector3(fx, 0.95, FRONT + 0.02),
			Vector3(0.24, 2.14, 0.28), VoxelSkin.WOOD))
	out.append(VoxelSkin.box(Vector3(0.0, 2.02, FRONT + 0.02),
		Vector3(1.28, 0.24, 0.28), VoxelSkin.WOOD))
	## ③ 遮阳棚（含支柱）
	for a in _awning():
		out.append(VoxelSkin.box(a[0], a[1] * 2.0, VoxelSkin.AWNING))
	for sx in [-1.0, 1.0]:
		out.append(VoxelSkin.box(Vector3(sx, 0.87, FRONT + 0.80),
			Vector3(0.12, 1.74, 0.12), VoxelSkin.WOOD))
	## ④ 屋顶
	var r := _roof()
	var ry0: float = r[0][0].y - r[0][1].y
	var ry1: float = r[r.size() - 1][0].y + r[r.size() - 1][1].y
	out.append(VoxelSkin.band_y(ry0, ry1, 1.7, VoxelSkin.ROOF))
	## ⑤ 屋檐木梁
	for e in _eaves():
		out.append(VoxelSkin.box(e[0], e[1] * 2.0, VoxelSkin.WOOD))
	## ⑥ 二三层外墙：浅棕
	out.append(VoxelSkin.band_y(H1, ry0, 1.7, VoxelSkin.SAND))
	## ⑦ 兜底：一层奶油色外墙
	out.append(VoxelSkin.all(local_bounds(), VoxelSkin.CREAM))
	return out

func meta() -> Dictionary:
	return {
		&"tag": "bakery",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(0, 0, 1),
	}
