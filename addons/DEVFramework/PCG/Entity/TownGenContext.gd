class_name TownGenContext extends RefCounted
## 城镇生成上下文 — TownStepDef 步骤间共享读写的数据载体
##
## 每个步骤通过 ctx 读写共享状态（选址/路网/建筑/动态层），
## 实现步骤间解耦：步骤只依赖 ctx，不依赖其它步骤实例。

var def: TownDef
var heightmap: HeightMap = null
var seed_base: int = 0
var layout: TownLayout
var site := Vector2i.ZERO
var site_score := 0.0
## 最大陆地连通域格线性索引（选址产出，供枢纽/行道树等使用）
var main_cells := PackedInt32Array()
var _slot := 0


func _init(town_def: TownDef = null, hmap: HeightMap = null, base_seed: int = 0) -> void:
	def = town_def
	heightmap = hmap
	seed_base = base_seed
	var w: int = town_def.width if town_def else 96
	var h: int = town_def.height if town_def else 96
	layout = TownLayout.new()
	layout.roads_grid = GeneratedGrid.create(w, h, 0)


func next_rng() -> RandomNumberGenerator:
	_slot += 1
	return PCGTool.make_rng(PCGTool.derive_seed(seed_base, 10 + _slot))
