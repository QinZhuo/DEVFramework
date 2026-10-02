@tool
class_name BenchGen
extends PropGen
## 用例四道具 —— 长椅
##
## 座板刻意做成**三块前后错开的板**而不是一整块：体素场景里大面积单色会糊成一片，
## 板与板之间的错位会在体素网格上形成一道真实的暗线，勾出水平方向。
## 这是"用结构造细节"，比加贴图便宜得多，也比加几何便宜。
##
## ============================ 所有板厚都 ≥ 一个体素 ============================
## 本场景统一 0.2 米体素（见 [constant DioramaPresets.CELL]），而体素化是在
## 0.2 米的格点采样上做的：比它薄的板只有落在采样面上才留得住，落在两片采样面
## 之间就**整块消失**。初版座板厚 0.09 米，四条腿也是 0.09 米 —— 结果整张长椅
## 一个体素都没出，[method PropBuild.has_voxel] 变假，场景安静地退回网格形态，
## 日志一切正常（[method DioramaBuild.validate] 才会报"体素化退化"）。
## 所以这里的厚度一律取 0.22 米（≈1.1 格），宁可粗一点也不要掉块。

const HW := 0.70   ## 半长
const HD := 0.26   ## 半深
const SEAT := 0.46 ## 座面中心高度
const TH := 0.11   ## 板 / 腿半厚（0.22 米 ≈ 1.1 格）
const LEG := 0.23  ## 腿半高：腿顶正好顶到座板底 0.35

func local_bounds() -> AABB:
	return AABB(Vector3(-HW, 0.0, -0.40), Vector3(HW * 2.0, 1.00, 0.76))


func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		var d := 1e9
		## 座板三块，前后各挑出一点
		for i in 3:
			var z := -0.21 + 0.21 * float(i)
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(0.0, SEAT, z), Vector3(HW, TH, 0.10)))
		## 靠背：两条横板
		for y in [0.74, 0.90]:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(0.0, y, -0.30), Vector3(HW, TH, 0.09)))
		## 靠背立柱：两条竖板，把横板与座板连起来（不连的话体素化后靠背会悬空）
		for sx in [-1.0, 1.0]:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(sx * (HW - 0.12), 0.66, -0.30),
				Vector3(0.10, 0.34, 0.09)))
		## 四条腿
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				d = SdfTool.op_union(d, SdfTool.sd_box(
					p - Vector3(sx * (HW - 0.12), LEG, sz * 0.19),
					Vector3(TH, LEG, TH)))
		return d)


func voxel_regions() -> Array:
	var out := []
	## 木质部分（座板 + 靠背）
	out.append(VoxelSkin.band_y(0.40, 1.00, HW + 0.01, VoxelSkin.WOOD))
	## 金属腿
	out.append(VoxelSkin.band_y(0.0, 0.40, HW + 0.01, VoxelSkin.METAL))
	out.append(VoxelSkin.all(local_bounds(), VoxelSkin.METAL))
	return out


func meta() -> Dictionary:
	return {&"tag": "bench", &"surface_snap": true, &"wants_ground": true}