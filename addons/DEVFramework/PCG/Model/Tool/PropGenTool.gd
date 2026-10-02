@tool
class_name PropGenTool
## 单体生成器驱动工具 —— 负责"同一个 seed 永远烘焙出同一个单体"
##
## 全部静态、无状态。缓存策略交给调用方（项目层），
## 因为"缓存多久 / 存多少"是玩法决策，不是框架决策。
##
## 对应 PCG 层的 PCGTool：那边管"数据怎么可复现地长出来"，
## 这边管"单体几何怎么可复现地长出来"。

## 派生随机源。salt 让同一个 seed 能派生出互不相关的多个流
## （例如"外形用 0、配色用 1、细节用 2"）。
##
## 注意：**不要**在设完 seed 后再写 `r.state = r.seed`。Godot 的
## RandomNumberGenerator 是 PCG32，seed 与 state 是两个不同概念 ——
## 赋值 seed 会用 PCG 初始化状态（state + increment），而 state 是"当前状态"。
## 把 state 覆盖成 seed 的整数值（往往是很小的数）会让序列退化：
## 不同 seed 的首次取值会塌成同一个值，整个 seed 就此失效。
## 正确做法与 [PCGTool.make_rng] 一致：只设 seed。
static func make_rng(seed_value: int, salt := 0) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	if salt == 0:
		r.seed = seed_value
	else:
		r.seed = (seed_value ^ (salt * 0x9E3779B1)) & 0x7FFFFFFF
	return r

## 组合 seed —— 让"哪一栋楼"与"整张地图"解耦：
## 换地图 seed 不该改变已有建筑的形状，只改变它们的摆放。
static func mix_seed(world_seed: int, kind: int, index: int) -> int:
	var h := world_seed & 0xFFFFFFFF
	h = (h ^ (kind * 0x9E3779B1)) & 0x7FFFFFFF
	h = (h ^ (index * 0x85EBCA6B)) & 0x7FFFFFFF
	h = (h ^ (h >> 13)) & 0x7FFFFFFF
	return h

## 用指定 Def / seed 装配并烘焙一个生成器。
static func bake(gen: PropGen, def: PropGenDef, seed_value: int, salt := 0) -> PropBuild:
	if gen == null:
		return null
	gen.gen_def = def
	gen.rng = make_rng(seed_value, salt)
	return gen.generate()

## 把 PropBuild 实例化为节点。父节点负责世界变换 ——
## 本工具不碰位置，位置归 [PropLayoutTool]。
static func instantiate(build: PropBuild, material: Material = null) -> MeshInstance3D:
	if build == null or build.is_empty():
		return null
	return build.to_mesh_instance(material)
