@tool
class_name PropRecipe
extends Resource
## 单体配方 —— 告诉 [WorldAssembler] "这个世界要哪些种类的东西、各多少个、摆哪"
##
## 配方里**没有**任何几何描述：形状由 [PropGen] 子类的代码决定，
## 这里只声明"要 ShopGen、摆 12 个、沿街两侧、面朝街道"。
##
## 这就是"不许一个世界数据包吞掉所有内容"的落地形式：
## 世界 = 一组配方 + 一个组装器，内容永远留在各自的生成器里。

## 摆放策略
enum Place {
	STREET,       ## 主街本体：沿 +X 首尾相铺，是其余单体的锚
	STREET_SIDE,  ## 沿街两侧，面朝街道（店铺）
	ROADSIDE,     ## 停在路肩，车头顺着街道（车辆）
	LANDMARK,     ## 独立地块，不依附街道（医院等大体量建筑）
}

@export var tag := "prop"              ## 分类标签，同时用于缓存键
@export var gen_script: Script         ## 生成器脚本（须 extends PropGen）
@export var count := 4                 ## 数量
@export_range(0.02, 0.5, 0.01) var voxel_size := 0.18   ## 烘焙精度
@export var place: Place = Place.STREET_SIDE
@export var sharp_normal := true       ## 主平面特征法线（三渲二硬边）
@export var sharpen := 0.0             ## 硬边化步长，0 = 光滑

## —— 双产物 ——
## 与 [PropGenDef] 的同名字段一一对应，由 [method make_gen_def] 原样带下去。
##
## 为什么配方也要有这两个：世界组装走的是"每个配方自己 [method make_gen_def]"，
## 而不是共用装配器上的某个 Def。因此风格包想把"这套场景出体素"传下去，
## 必须落到**每个配方**上，只改包自己的 Def 是无效的 ——
## 曾经就因为这个，微缩风格明明设了 voxel_res=64，组装结果里一个体素都没有。
@export_range(0, 256, 1) var voxel_res := 0        ## 体素最长边分辨率，0 = 不产体素
@export var voxel_palette: ToonPaletteDef = null    ## 体素调色板，空则用默认色

## 摆放微调
@export var align_to_street := true    ## 正面是否朝向街道
@export var y_offset := 0.0            ## 额外抬高
@export_range(0.3, 1.0, 0.01) var spacing := 0.95   ## 沿街间隔系数

## 稳定的 kind 编号：用于 [method PropGenTool.mix_seed] 派生单体 seed。
## 同一类配方在列表里的位置不该影响结果 —— 调整摆放顺序不该改变已有建筑的形状。
@export var kind_id := 0

func make_gen_def() -> PropGenDef:
	var d := PropGenDef.new()
	d.voxel_size = voxel_size
	d.margin = 0.4
	d.algo = MeshExtractor.Algo.DUAL_CONTOURING
	d.sharp_normal = sharp_normal
	d.sharpen = sharpen
	d.voxel_res = voxel_res
	d.voxel_palette = voxel_palette
	return d
