@tool
class_name CustomerGen
extends PropGen
## 用例四道具 —— 体素顾客
##
## 用例四点名要"两个体素顾客"。它们的作用是**给比例尺**：没有人的参照，
## 8 米高的建筑在画面上就是个抽象体块；两个 1.55 米的人一站进去，
## "这是街角"这件事立刻成立。
##
## 姿势参数化：[member _arm_up] 让两人一个有抬手（招呼店主）、一个垂手，
## 两个一模一样的立人会读成"复制粘贴"，这是场景里最容易露怯的地方。
##
## 四肢厚度都取 0.13~0.15 米（≥ 一个体素边长，见 [constant DioramaPresets.CELL]）。
## 按人体比例做细（初版手臂 0.096 米）的后果不是"精致"，而是体素化时
## 四肢整条掉光 —— 实测 0.2 米体素下整个人只剩 16 块，认不出是个人。

const H := 1.55

var _cloth := VoxelSkin.CLOTH1   ## 上衣色，两名顾客不同
var _arm_up := false             ## 一只手抬到胸前

func prepare() -> void:
	## 索引在两个衣服色里挑一个。别用 randi() 直接取 12~13 ——
	## 那依赖全局种子顺序，换个 seed 会漂。这里锁死取值域，seed 只决定选哪个。
	_cloth = VoxelSkin.CLOTH1 if rng.randf() < 0.5 else VoxelSkin.CLOTH2
	_arm_up = rng.randf() < 0.5

func local_bounds() -> AABB:
	return AABB(Vector3(-0.27, 0.0, -0.14), Vector3(0.54, H, 0.28))

func build(_field: SdfField) -> void:
	var up := _arm_up
	fill_shape(func(p: Vector3) -> float:
		## 腿
		var d := 1e9
		for sx in [-0.085, 0.085]:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(sx, 0.33, 0.0), Vector3(0.07, 0.33, 0.075)))
		## 躯干
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 0.92, 0.0), Vector3(0.155, 0.26, 0.11)))
		## 手臂：垂手 / 一手抬起
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(-0.205, 0.88, 0.0), Vector3(0.065, 0.22, 0.075)))
		if up:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(0.205, 1.00, 0.0), Vector3(0.065, 0.10, 0.075)))
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(0.155, 0.80, 0.06), Vector3(0.10, 0.065, 0.075)))
		else:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(0.205, 0.88, 0.0), Vector3(0.065, 0.22, 0.075)))
		## 头
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 1.33, 0.0), Vector3(0.135, 0.15, 0.13)))
		## 头发：比头略大的厚顶，压住头顶
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 1.44, -0.01), Vector3(0.14, 0.075, 0.135)))
		return d)

func voxel_regions() -> Array:
	var out := [
		## 头发
		VoxelSkin.box(Vector3(0.0, 1.44, -0.01), Vector3(0.30, 0.16, 0.28), VoxelSkin.WOOD),
		## 头 + 抬起的那只手
		VoxelSkin.box(Vector3(0.0, 1.33, 0.0), Vector3(0.28, 0.30, 0.27), VoxelSkin.SKIN),
	]
	if _arm_up:
		out.append(VoxelSkin.box(Vector3(0.155, 0.80, 0.06),
			Vector3(0.21, 0.14, 0.16), VoxelSkin.SKIN))
	out.append(VoxelSkin.all(local_bounds(), _cloth))
	return out

func meta() -> Dictionary:
	return {&"tag": "customer", &"surface_snap": true, &"wants_ground": true}
