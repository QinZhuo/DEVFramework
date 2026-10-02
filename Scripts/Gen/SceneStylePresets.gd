@tool
class_name SceneStylePresets
extends RefCounted
## 内置场景风格包 —— **项目层**：具体预设属于内容语义，不进框架
##
## [SceneStylePack] 只描述"风格包长什么样"（画风 + 配色 + 配方表 + 布局参数 + 输出形态），
## 那三套具体预设引用的是本项目的生成器脚本（[code]res://Scripts/Gen/*.gd[/code]），
## 按 [code]addons/DEVFramework/LAYERS.md[/code] 的红线，框架不得出现项目路径，
## 因此预设落在这里。调用一律走 [method presets]。
##
## 三套刻意**内容不同、画风不同、布局参数也不同**，
## 用来验证"切一个配置换整个场景"是真的成立，而不只是换了个材质。
##
## == 用法 ==
## [codeblock]
## var pack = SceneStylePresets.presets()[&"wa_shrine"]
## [/codeblock]


## `StringName → SceneStylePack`。
static func presets() -> Dictionary:
	return {
		&"jp_street": _jp_street(),
		&"wa_shrine": _wa_shrine(),
		&"mini_fairy": _mini_fairy(),
	}


# ================================================================== 三套预设

## 日式街道 —— 现成内容直接复用，画风走"清透日系"
static func _jp_street() -> SceneStylePack:
	var p := SceneStylePack.new()
	p.title = "日式街道"
	p.desc = "2 档硬边色阶 + 细描边，街边店面沿主街排布。最通用的默认画风。"
	p.style = ToonStyleDef.presets()[&"anime_clean"]
	p.palette = ToonPaletteDef.presets()[&"anime_daylight"]
	p.gen_def = _gen(0.30, 0.0, 0)
	p.street_step = 4.0
	p.output = SceneStylePack.Output.MESH
	p.recipes = [
		_r("street", "res://Scripts/Gen/StreetGen.gd", 3, PropRecipe.Place.STREET, 0.40),
		_r("shop", "res://Scripts/Gen/ShopGen.gd", 6, PropRecipe.Place.STREET_SIDE, 0.30),
		_r("vehicle", "res://Scripts/Gen/VehicleGen.gd", 4, PropRecipe.Place.ROADSIDE, 0.20),
		_r("hospital", "res://Scripts/Gen/HospitalGen.gd", 1, PropRecipe.Place.LANDMARK, 0.40),
	]
	return p


## 和风神社 —— 薄壳 + 和风配色，内容为参道 / 鸟居 / 石灯笼 / 社殿
static func _wa_shrine() -> SceneStylePack:
	var p := SceneStylePack.new()
	p.title = "和风神社"
	p.desc = "薄壳抽壳 + 3 档柔过渡 + 生成り白与朱红。参道两侧石灯笼，尽头鸟居与社殿。"
	p.style = ToonStyleDef.presets()[&"wa_shoji"]
	p.palette = ToonPaletteDef.presets()[&"wa_fu"]
	## 和风走薄壳：抽壳会让墙面变薄，体素要细一点才不漏
	p.gen_def = _gen(0.26, 0.0, 0)
	p.street_step = 5.0
	p.output = SceneStylePack.Output.MESH
	## ★ 摆放策略的硬约束：[WorldAssembler] 的 STREET 是**唯一主街**，
	## `_recipe_at()` 只取第一个 STREET 配方、其余 STREET 配方在 assemble_finish 里直接 pass。
	## 于是"路面上再摆一种东西"必须改用 ROADSIDE —— 曾经把鸟居设成 STREET，
	## 结果是 2 座鸟居一座都没摆出来，且**没有任何报错**，只是 quietly 消失。
	p.recipes = [
		_r("street", "res://Scripts/Gen/StreetGen.gd", 3, PropRecipe.Place.STREET, 0.34),
		_r("torii", "res://Scripts/Gen/ToriiGen.gd", 2, PropRecipe.Place.ROADSIDE, 0.26),
		_r("lantern", "res://Scripts/Gen/LanternGen.gd", 8, PropRecipe.Place.STREET_SIDE, 0.16),
		_r("shrinehall", "res://Scripts/Gen/ShrineHallGen.gd", 1, PropRecipe.Place.LANDMARK, 0.30),
	]
	return p


## 微缩童话 —— 极高明度 + 重雾，摆一座台座上的糖果屋聚落，默认出体素
static func _mini_fairy() -> SceneStylePack:
	var p := SceneStylePack.new()
	p.title = "微缩童话"
	p.desc = "低对比 + 强环境光 + 极细描边 + 重雾，模拟放在桌上看的树脂模型。默认出体素。"
	p.style = ToonStyleDef.presets()[&"miniature_diorama"]
	p.palette = ToonPaletteDef.presets()[&"miniature"]
	## 微缩要"看清体素块"，分辨率给足；sharpen 给一点点，让块面更硬
	p.gen_def = _gen(0.22, 0.06, 64)
	p.street_step = 6.0
	p.output = SceneStylePack.Output.VOXEL
	## 童话村同样需要一条主街：STREET_SIDE 的落位**依赖街道当锚**，
	## 没有 street 配方时它们会全部退化到 (0, ±40) 两个点上互相穿插。
	##
	## ★ 数量受街道段数约束：STREET_SIDE 是"每段街道一个、左右交替"，
	## 于是同 tag 的数量**不能超过街段数** —— 多出来的会叠回同一个锚点，
	## 靠 relax 推不开（糖果屋直径近 4 米，重叠深度远大于迭代能消掉的位移）。
	## 灯笼改走 ROADSIDE，避开糖果屋那一侧，免得两类抢同一条路缘。
	p.recipes = [
		_r("street", "res://Scripts/Gen/StreetGen.gd", 3, PropRecipe.Place.STREET, 0.34),
		_r("candyhouse", "res://Scripts/Gen/CandyHouseGen.gd", 3, PropRecipe.Place.STREET_SIDE, 0.18),
		_r("lantern", "res://Scripts/Gen/LanternGen.gd", 3, PropRecipe.Place.ROADSIDE, 0.16),
	]
	return p


# ================================================================== 内部

## 造烘焙 Def。[param vres] 为体素最长边分辨率，0 = 不产体素。
static func _gen(voxel: float, sharpen: float, vres: int) -> PropGenDef:
	var d := PropGenDef.new()
	d.voxel_size = voxel
	d.margin = 0.4
	d.algo = MeshExtractor.Algo.DUAL_CONTOURING
	d.sharp_normal = true
	d.sharpen = sharpen
	d.voxel_res = vres
	return d


## 造配方。kind_id 用 tag 哈希派生 —— 同一个 tag 在哪个列表位置都拿到同一编号，
## 于是"调整摆放顺序"不会改变已有单体的形状（见 [method PropGenTool.mix_seed]）。
static func _r(tag: String, script_path: String, count: int,
		place: PropRecipe.Place, voxel: float) -> PropRecipe:
	var r := PropRecipe.new()
	r.tag = tag
	r.gen_script = load(script_path)
	r.count = count
	r.place = place
	r.voxel_size = voxel
	r.sharp_normal = true
	r.kind_id = tag.hash() % 97
	return r
