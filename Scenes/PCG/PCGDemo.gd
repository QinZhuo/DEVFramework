extends Control
## PCG 演示 · 程序化生成功能展示
##
## 通过 Assets/Def/PCG/ 下的预置配置资源展示四类生成：
##   噪声层 (NoiseLayerDef) / 网格生成 (GridGenDef) / 散布放置 (PlacementDef) / 内容生成 (ContentGenDef)
## 全部为配置驱动（.tres），本脚本只负责把生成结果渲染出来。

enum Mode {
	NOISE,
	GRID,
	PLACE,
	CONTENT,
	BIOME,
	PIPELINE,
	PATH,
}

@export var noise_defs: Array[Resource] = []
@export var grid_defs: Array[Resource] = []
@export var placement_defs: Array[Resource] = []
@export var content_defs: Array[Resource] = []
@export var biome_defs: Array[Resource] = []
@export var pipeline_defs: Array[Resource] = []
@export var path_defs: Array[Resource] = []

@onready var texture_rect: TextureRect = %TextureRect
@onready var mode_option: OptionButton = %ModeOption
@onready var sub_option: OptionButton = %SubOption
@onready var seed_spin: SpinBox = %SeedSpin
@onready var log_box: RichTextLabel = %LogBox
@onready var brush_row: HBoxContainer = $UI/VBox/RowBrush
@onready var brush_option: OptionButton = $UI/VBox/RowBrush/BrushOption
@onready var clear_button: Button = $UI/VBox/RowBrush/ClearButton
@onready var anim_row: HBoxContainer = $UI/VBox/RowAnim
@onready var anim_check: CheckButton = $UI/VBox/RowAnim/AnimCheck
@onready var anim_reset: Button = $UI/VBox/RowAnim/AnimReset

var _mode := Mode.NOISE
## WFC 固定格：{Vector2i(格坐标): 瓦片索引}，左键点击纹理涂色后参与生成
var _wfc_fixed := {}
var _brush_index := 0
## WFC 生成过程动画
var _animator: WFCAnimator
var _animating := false


func _ready() -> void:
	# 与 Mode 枚举一一对应的中文标签
	var labels := ["噪声层", "网格生成", "散布放置", "内容生成", "生物群系", "综合管线", "河流道路"]
	for i in labels.size():
		mode_option.add_item(labels[i], i)
	mode_option.selected = _mode
	sub_option.item_selected.connect(func(_idx: int) -> void: _generate())
	seed_spin.value_changed.connect(func(_v: float) -> void: _generate())
	brush_option.item_selected.connect(func(_i: int) -> void: _brush_index = _i)
	clear_button.pressed.connect(_on_clear_fixed)
	anim_check.toggled.connect(_on_anim_toggled)
	anim_reset.pressed.connect(_on_anim_reset)
	texture_rect.gui_input.connect(_on_texture_gui_input)
	_reload_sub_options()


func _process(_delta: float) -> void:
	if not _animating or _animator == null:
		return
	var steps_per_frame := 12
	for i in steps_per_frame:
		if _animator.step():
			_on_animation_finished()
			return  # 已完成，回调内已重建静态图
	var img := _animator.render_image()
	_draw_fixed_highlight(img, _selected_def(grid_defs) as GridGenDef)
	texture_rect.texture = ImageTexture.create_from_image(_scale_up(img))


func _on_mode_selected(idx: int) -> void:
	_mode = idx
	_reload_sub_options()


func _on_regenerate_pressed() -> void:
	_generate()


## —— 展示区 ——

func _reload_sub_options() -> void:
	sub_option.clear()
	match _mode:
		Mode.NOISE:
			_add_options(noise_defs)
		Mode.GRID:
			_add_options(grid_defs)
		Mode.PLACE:
			_add_options(placement_defs)
		Mode.CONTENT:
			_add_options(content_defs)
		Mode.BIOME:
			_add_options(biome_defs)
		Mode.PIPELINE:
			_add_options(pipeline_defs)
		Mode.PATH:
			_add_options(path_defs)
	_generate()


func _add_options(defs: Array[Resource]) -> void:
	for i in defs.size():
		var d: Resource = defs[i]
		var label := ""
		if d and not d.resource_path.is_empty():
			label = d.resource_path.get_file().get_basename()
		if label.is_empty():
			label = "资源%d" % i
		sub_option.add_item(label, i)


func _selected_def(defs: Array[Resource]) -> Resource:
	if sub_option.selected < 0 or sub_option.selected >= defs.size():
		return null
	return defs[sub_option.selected]


func _generate() -> void:
	if _animating:
		_animating = false
		_animator = null
	var seed := int(seed_spin.value)
	match _mode:
		Mode.NOISE:
			_gen_noise(seed)
		Mode.GRID:
			_gen_grid(seed)
		Mode.PLACE:
			_gen_place(seed)
		Mode.CONTENT:
			_gen_content(seed)
		Mode.BIOME:
			_gen_biome(seed)
		Mode.PIPELINE:
			_gen_pipeline(seed)
		Mode.PATH:
			_gen_path(seed)


## —— 噪声层 / 程序化纹理 ——

func _gen_noise(seed: int) -> void:
	var res := _selected_def(noise_defs)
	if res is TextureGenDef:
		_gen_texture(res as TextureGenDef, seed)
		return
	var def := res as NoiseLayerDef
	if def == null:
		_log("请配置 noise_defs（参考 Scenes/PCG/PCGDemo.tscn）")
		return
	var img := PCGTool.noise_image(def, 256, 256, seed)
	texture_rect.texture = ImageTexture.create_from_image(_scale_up(img))
	_log("噪声层: %s\nseed=%d  type=%s" % [def.name, seed, def.get_desc(null)])


func _gen_texture(def: TextureGenDef, seed: int) -> void:
	brush_row.visible = false
	anim_row.visible = false
	var img := PCGTool.generate_texture(def, PCGTool.make_rng(seed))
	texture_rect.texture = ImageTexture.create_from_image(_scale_up(img))
	_log("纹理: %s\nseed=%d  type=%s  %d x %d" % [
		def.name, seed, TextureGenDef.Type.keys()[def.type], img.get_width(), img.get_height(),
	])


## —— 网格生成 ——

func _gen_grid(seed: int) -> void:
	var res := _selected_def(grid_defs)
	if res is LSystemDef:
		_gen_lsystem(res as LSystemDef, seed)
		return
	if res is HeightMapDef:
		_gen_heightmap(res as HeightMapDef, seed)
		return
	if res is TemplateStitchDef:
		_gen_stitch(res as TemplateStitchDef, seed)
		return
	if res is CityDef:
		_gen_city(res as CityDef, seed)
		return
	var def := res as GridGenDef
	if def == null:
		_log("请配置 grid_defs")
		return
	var is_wfc := def.type == GridGenDef.Type.WFC
	brush_row.visible = is_wfc
	anim_row.visible = is_wfc
	if is_wfc:
		_fill_brush_options(def)
	var fixed := _wfc_fixed.duplicate()
	var grid := PCGTool.generate_grid(def, PCGTool.make_rng(seed), fixed)
	var img: Image
	if is_wfc and def.tile_set:
		# WFC 结果按瓦片索引着色
		var palette := {}
		for i in def.tile_set.tiles.size():
			palette[i] = def.tile_set.tiles[i].color
		img = PCGTool.grid_to_image(grid, palette)
		_draw_fixed_highlight(img, def)
	else:
		img = PCGTool.grid_to_image(grid, {
			def.solid_value: Color(0.16, 0.18, 0.22),
			def.empty_value: Color(0.88, 0.9, 0.93),
		})
	texture_rect.texture = ImageTexture.create_from_image(_scale_up(img))
	if is_wfc:
		var counts := {}
		for c in grid.cells:
			counts[c] = counts.get(c, 0) + 1
		_log("网格: %s（WFC，固定格 %d）\n%s\n左键涂色 / 右键擦除，再点“重新生成”自动补全" % [
			def.name, _wfc_fixed.size(), counts,
		])
	else:
		var comps := grid.components(def.solid_value)
		var empty_comps := grid.components(def.empty_value)
		_log("网格: %s\n%d x %d  solid=%d  empty=%d  实体连通域=%d  空地连通域=%d" % [
			def.name, grid.width, grid.height,
			grid.count(def.solid_value), grid.count(def.empty_value),
			comps.size(), empty_comps.size(),
		])


## —— WFC 固定格交互 ——

func _fill_brush_options(def: GridGenDef) -> void:
	brush_option.clear()
	var tiles := def.tile_set.tiles if def.tile_set else []
	for i in tiles.size():
		brush_option.add_item(tiles[i].name, i)
	_brush_index = clampi(_brush_index, 0, maxi(0, tiles.size() - 1))
	brush_option.selected = _brush_index


func _on_texture_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	if not event.pressed:
		return
	var def := _selected_def(grid_defs) as GridGenDef
	if def == null or def.type != GridGenDef.Type.WFC:
		return
	var gpos := _texture_to_grid(event.position, def)
	if gpos.x < 0:
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		_wfc_fixed[gpos] = _brush_index
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		_wfc_fixed.erase(gpos)
	else:
		return
	_generate()


func _on_clear_fixed() -> void:
	_wfc_fixed.clear()
	_generate()


## —— WFC 生成过程动画 ——

func _on_anim_toggled(on: bool) -> void:
	if on:
		_start_animation()
	else:
		if _animating:
			_animating = false
			_animator = null
		_generate()


func _start_animation() -> void:
	var def := _selected_def(grid_defs) as GridGenDef
	if def == null or def.type != GridGenDef.Type.WFC:
		anim_check.button_pressed = false
		return
	_animator = WFCAnimator.new()
	_animator.setup(def, PCGTool.make_rng(int(seed_spin.value)), _wfc_fixed.duplicate())
	_animating = true
	_log("WFC 动画开始：观测→传播（%s，固定格 %d）" % [def.name, _wfc_fixed.size()])


## 重置为未生成状态：清空动画并重新从初始波函数播放
func _on_anim_reset() -> void:
	if _animator == null:
		_start_animation()
		return
	_animator.setup(_animator.def, PCGTool.make_rng(int(seed_spin.value)), _wfc_fixed.duplicate())
	_animating = true
	_log("已重置为未生成状态")


func _on_animation_finished() -> void:
	var steps := _animator.step_count if _animator else 0
	var failed := _animator.failed if _animator else false
	_animating = false
	_animator = null
	anim_check.button_pressed = false  # 触发 toggled(false) → 重新生成最终静态图
	var tail := "（含矛盾格，已由重试兜底）" if failed else ""
	_log("WFC 动画完成：%d 步%s" % [steps, tail])


## 在生成图上给固定格描一圈亮色边框，方便看出哪些格是手动固定的
func _draw_fixed_highlight(img: Image, def: GridGenDef) -> void:
	var border := Color(1.0, 0.95, 0.6)
	for key in _wfc_fixed:
		var gx := -1
		var gy := -1
		if key is Vector2i:
			gx = key.x
			gy = key.y
		elif key is String:
			var parts := String(key).split(",")
			if parts.size() == 2:
				gx = int(parts[0])
				gy = int(parts[1])
		if gx < 0 or gy < 0 or gx >= def.width or gy >= def.height:
			continue
		# 上/下边
		for i in range(maxi(0, gx - 1), mini(def.width, gx + 2)):
			if gy >= 0 and gy < def.height:
				img.set_pixel(i, gy, border)
			if gy + 1 >= 0 and gy + 1 < def.height:
				img.set_pixel(i, gy + 1, border)
		# 左/右边
		for j in range(maxi(0, gy - 1), mini(def.height, gy + 2)):
			if gx >= 0 and gx < def.width:
				img.set_pixel(gx, j, border)
			if gx + 1 >= 0 and gx + 1 < def.width:
				img.set_pixel(gx + 1, j, border)


## 把生成的小图用最近邻放大到清晰尺寸（避免 1px 格被插值模糊）
func _scale_up(img: Image) -> Image:
	if img.get_width() < 512:
		var s := 768.0 / img.get_width()
		img.resize(int(img.get_width() * s), int(img.get_height() * s), Image.INTERPOLATE_NEAREST)
	return img


## 把 TextureRect 上的点击坐标映射回网格格坐标（考虑居中留白）
func _texture_to_grid(pos: Vector2, def: GridGenDef) -> Vector2i:
	if texture_rect.texture == null:
		return Vector2i(-1, -1)
	var tex_size := texture_rect.texture.get_size()
	var view_size := texture_rect.size
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return Vector2i(-1, -1)
	var scale := minf(view_size.x / tex_size.x, view_size.y / tex_size.y)
	var draw_size := Vector2(tex_size.x * scale, tex_size.y * scale)
	var origin := (view_size - draw_size) * 0.5
	if pos.x < origin.x or pos.y < origin.y or pos.x >= origin.x + draw_size.x or pos.y >= origin.y + draw_size.y:
		return Vector2i(-1, -1)
	var tx := int((pos.x - origin.x) / scale)
	var ty := int((pos.y - origin.y) / scale)
	if tx < 0 or ty < 0 or tx >= def.width or ty >= def.height:
		return Vector2i(-1, -1)
	return Vector2i(tx, ty)


## —— 高度图 ——

func _gen_heightmap(def: HeightMapDef, seed: int) -> void:
	brush_row.visible = false
	anim_row.visible = false
	var hm := PCGTool.generate_heightmap(def, PCGTool.make_rng(seed))
	# 伪彩色：海蓝 → 沙滩 → 草地 → 山地 → 雪顶
	var img := Image.create(hm.width, hm.height, false, Image.FORMAT_RGB8)
	var sea := Color(0.15, 0.4, 0.7)
	var sand := Color(0.85, 0.8, 0.5)
	var grass := Color(0.3, 0.6, 0.3)
	var rock := Color(0.5, 0.45, 0.4)
	var snow := Color(0.95, 0.95, 0.95)
	for i in hm.heights.size():
		var h := hm.heights[i]
		var c: Color
		if h < 0.45:
			c = sea.lerp(sand, h / 0.45)
		elif h < 0.55:
			c = sand.lerp(grass, (h - 0.45) / 0.1)
		elif h < 0.8:
			c = grass.lerp(rock, (h - 0.55) / 0.25)
		else:
			c = rock.lerp(snow, (h - 0.8) / 0.2)
		img.set_pixel(i % hm.width, i / hm.width, c)
	texture_rect.texture = ImageTexture.create_from_image(_scale_up(img))
	var hist := hm.histogram(5)
	var land := 0
	for i in hm.heights.size():
		if hm.heights[i] >= 0.5:
			land += 1
	_log("高度图: %s\n%d x %d  陆地 %.1f%%  分层(海/低/中/高/峰)=%s\n可导出: heightmap_to_grid(2D栅格) / heightmap_to_grid3d(体素)" % [
		def.name, hm.width, hm.height, float(land) / hm.heights.size() * 100.0, str(hist),
	])


## —— L-System ——

func _gen_lsystem(def: LSystemDef, seed: int) -> void:
	brush_row.visible = false
	anim_row.visible = false
	var segs := PCGTool.generate_lsystem(def, PCGTool.make_rng(seed))
	var img := PCGTool.lsystem_to_image(segs, Vector2i(256, 256))
	texture_rect.texture = ImageTexture.create_from_image(_scale_up(img))
	_log("L-System: %s\nseed=%d  线段 %d  迭代 %d  angle=%d" % [
		def.name, seed, segs.size() / 2, def.iterations, def.angle_deg,
	])


## —— 模板拼接 ——

func _gen_stitch(def: TemplateStitchDef, seed: int) -> void:
	brush_row.visible = false
	anim_row.visible = false
	var grid := PCGTool.generate_template_stitch(def, PCGTool.make_rng(seed))
	var img := PCGTool.grid_to_image(grid, {
		def.solid_value: Color(0.16, 0.18, 0.22),
		def.empty_value: Color(0.88, 0.9, 0.93),
	})
	texture_rect.texture = ImageTexture.create_from_image(_scale_up(img))
	var comps := grid.components(def.empty_value)
	_log("模板拼接: %s\n%d 模板 %d x %d  空地连通域=%d" % [
		def.name, def.count, grid.width, grid.height, comps.size(),
	])


## —— 城镇 ——

func _gen_city(def: CityDef, seed: int) -> void:
	brush_row.visible = false
	anim_row.visible = false
	var layout := PCGTool.generate_town(def, null, seed)
	var grid := layout.roads_grid
	var img := Image.create(grid.width, grid.height, false, Image.FORMAT_RGB8)
	img.fill(Color(0.16, 0.24, 0.14))
	for pi in layout.parcels.size():
		var p = layout.parcels[pi]
		var c := Color(0.22, 0.3, 0.19) if pi % 2 == 0 else Color(0.26, 0.34, 0.22)
		if int(p.frontage_dir) < 0:
			c = c.darkened(0.3)
		for idx in p.cells:
			img.set_pixel(idx % grid.width, idx / grid.width, c)
	# 广场石板色 + 中心设施
	for idx in layout.plaza_cells:
		img.set_pixel(idx % grid.width, idx / grid.width, Color(0.6, 0.58, 0.52))
	if layout.plaza_center.x >= 0 and not layout.plaza_item.is_empty():
		var pc := layout.plaza_center
		img.set_pixel(pc.x, pc.y, Color(0.25, 0.22, 0.2))
		for dd in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if grid.get_cell(pc.x + dd.x, pc.y + dd.y, -1) == 0:
				img.set_pixel(pc.x + dd.x, pc.y + dd.y, Color(0.4, 0.38, 0.34))
	var palette := {
		def.road_main_value: Color(0.9, 0.78, 0.4),
		def.road_sec_value: Color(0.55, 0.56, 0.6),
		def.road_alley_value: Color(0.38, 0.39, 0.42),
		def.bridge_value: Color(0.45, 0.68, 0.85),
		def.road_ring_value: Color(0.72, 0.6, 0.35),
	}
	for i in grid.cells.size():
		var v: int = grid.cells[i]
		if v != 0 and palette.has(v):
			img.set_pixel(i % grid.width, i / grid.width, palette[v])
	# 建筑层：墙体按风格着色（木构深褐/石砌灰白/砖混红棕），设施石灰；地板暖木；门亮橙
	if layout.build_grid != null:
		var style_wall := {
			"木构": Color(0.32, 0.2, 0.12),
			"石砌": Color(0.5, 0.5, 0.48),
			"砖混": Color(0.45, 0.24, 0.18),
		}
		var cell_style := {}
		for bd in layout.buildings:
			var tag := String(bd.style) + ("|F" if String(bd.type) != "住宅" else "")
			for yy in range(bd.rect.position.y, bd.rect.end.y):
				for xx in range(bd.rect.position.x, bd.rect.end.x):
					cell_style[Vector2i(xx, yy)] = tag
		for i in layout.build_grid.cells.size():
			var bv: int = layout.build_grid.cells[i]
			var col := Color(0.36, 0.23, 0.14)
			var cpos := Vector2i(i % grid.width, i / grid.width)
			if bv == def.building_wall_value:
				var tag: String = cell_style.get(cpos, "")
				col = style_wall.get(tag.trim_suffix("|F"), col)
				if tag.ends_with("|F"):
					col = col.lightened(0.3)
			elif bv == def.building_floor_value:
				col = Color(0.62, 0.48, 0.3)
			elif bv == def.building_door_value:
				col = Color(1.0, 0.62, 0.15)
			else:
				continue
			img.set_pixel(cpos.x, cpos.y, col)
	# 家具(紫) 与 装饰物(灰褐) 与 院落围栏(深褐点)
	for k in layout.interiors:
		var v: Dictionary = layout.interiors[k]
		for sit in v.slots:
			var fc: Vector2i = sit.cell
			img.set_pixel(fc.x, fc.y, Color(0.72, 0.5, 0.9))
		for pit in v.props:
			var pc: Vector2i = pit.cell
			img.set_pixel(pc.x, pc.y, Color(0.42, 0.36, 0.28))
		for yc in v.get("yard", []):
			var yv: Vector2i = yc
			img.set_pixel(yv.x, yv.y, Color(0.28, 0.19, 0.11))
	img.set_pixel(layout.site.x, layout.site.y, Color(1.0, 0.45, 0.3))
	texture_rect.texture = ImageTexture.create_from_image(_scale_up(img))
	var frontage := 0
	for p in layout.parcels:
		if int(p.frontage_dir) >= 0:
			frontage += 1
	var furniture_n := 0
	for k in layout.interiors:
		furniture_n += (layout.interiors[k].slots as Array).size()
	_log("城镇: %s\n建筑 %d｜家具 %d｜地块 %d (临街 %d)" % [
		def.name, layout.buildings.size(), furniture_n, layout.parcels.size(), frontage,
	])


## —— 河流 / 道路 ——

func _gen_path(seed: int) -> void:
	brush_row.visible = false
	anim_row.visible = false
	var res := _selected_def(path_defs)
	var rng := PCGTool.make_rng(seed)
	# 用地形栅格作底：噪声地形(0=空, 1=陆)，河流/道路 stamp 上去
	var size := 96
	var terrain := GeneratedGrid.create(size, size, 0)
	var terrain_def := load("res://Assets/Def/PCG/Grid_NoiseTerrain.tres") as GridGenDef
	if terrain_def:
		terrain = PCGTool.generate_grid(terrain_def, PCGTool.make_rng(seed + 777))
	var img := PCGTool.grid_to_image(terrain, {
		1: Color(0.62, 0.66, 0.55),  # 陆地
		0: Color(0.25, 0.5, 0.7),    # 空地(海)
	})
	var info := ""
	if res is RiverDef:
		var def := res as RiverDef
		var paths := PCGTool.generate_river(def, rng)
		PCGTool.stamp_path(terrain, paths, def.river_value, def.width)
		info = "河流 %s: %d 段 宽 %d\n流经高度场梯度下降，蓝线=河道" % [
			def.name, def.river_count, def.width,
		]
		img = PCGTool.grid_to_image(terrain, {
			1: Color(0.62, 0.66, 0.55),
			0: Color(0.25, 0.5, 0.7),
			def.river_value: Color(0.25, 0.45, 0.9),
		})
	elif res is RoadDef:
		var def := res as RoadDef
		var roads := PCGTool.generate_road(def, rng)
		PCGTool.stamp_path(terrain, roads, def.road_value, def.road_width)
		info = "道路 %s: %d 枢纽 宽 %d%s\nL 型走廊连接，灰线=道路" % [
			def.name, def.hub_count, def.road_width, "（MST 最小生成树）" if def.mst_only else "",
		]
		img = PCGTool.grid_to_image(terrain, {
			1: Color(0.62, 0.66, 0.55),
			0: Color(0.25, 0.5, 0.7),
			def.road_value: Color(0.75, 0.75, 0.75),
		})
	else:
		_log("请配置 path_defs（RiverDef 或 RoadDef）")
		return
	texture_rect.texture = ImageTexture.create_from_image(_scale_up(img))
	_log("%s\nseed=%d  鼠标可点击下方区域" % [info, seed])


## —— 生物群系 ——

func _gen_biome(seed: int) -> void:
	var def := _selected_def(biome_defs) as BiomeMapDef
	if def == null:
		_log("请配置 biome_defs")
		return
	var bm := PCGTool.generate_biome(def, PCGTool.make_rng(seed))
	var img := PCGTool.biome_to_image(bm)
	texture_rect.texture = ImageTexture.create_from_image(_scale_up(img))
	var counts := {}
	for i in bm.indices:
		if i >= 0 and i < bm.biomes.size():
			counts[bm.biomes[i].name] = counts.get(bm.biomes[i].name, 0) + 1
	_log("生物群系: %s\n%s" % [def.name, counts])


## —— 综合管线 ——

## 运行 PCGDef 管线（地形→群系→资源点→战利品），合成一张世界总览图
func _gen_pipeline(seed: int) -> void:
	var def := _selected_def(pipeline_defs) as PCGDef
	if def == null:
		_log("请配置 pipeline_defs")
		return
	var out := PCGTool.generate(def, seed)
	var terrain: GeneratedGrid = out.get("terrain")
	var biome_map: BiomeMap = out.get("biomes")
	var resources: PackedVector2Array = out.get("resources", PackedVector2Array())
	var loot: Array = out.get("loot", [])
	var river: PackedVector2Array = out.get("river", PackedVector2Array())
	var road: PackedVector2Array = out.get("road", PackedVector2Array())
	# 从管线定义里找 terrain 生成器取 solid/empty 值（GeneratedGrid 本身不携带）
	var terrain_def: GridGenDef = null
	for g in def.generators:
		if g is GridGenDef and g._effective_key() == "terrain":
			terrain_def = g
			break
	var solid_val := terrain_def.solid_value if terrain_def else 1
	var empty_val := terrain_def.empty_value if terrain_def else 0
	# 合成总览：群系色为底 + 地形实体加深 + 河流/道路 + 资源点高亮
	var img: Image
	if biome_map:
		img = PCGTool.biome_to_image(biome_map)
	else:
		img = Image.create(96, 96, false, Image.FORMAT_RGB8)
		img.fill(Color(0.1, 0.1, 0.12))
	if terrain:
		for i in terrain.cells.size():
			if terrain.cells[i] == solid_val:
				var c: Color = img.get_pixel(i % terrain.width, i / terrain.width)
				img.set_pixel(i % terrain.width, i / terrain.width, c.darkened(0.45))
	_draw_path(img, river, Color(0.25, 0.55, 1.0), 1)
	_draw_path(img, road, Color(0.7, 0.7, 0.75), 1)
	# 资源点（黄色 2px 点）
	var dot := Color(1.0, 0.85, 0.2)
	for p in resources:
		var px := int(p.x)
		var py := int(p.y)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var x := px + dx
				var y := py + dy
				if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
					img.set_pixel(x, y, dot)
	texture_rect.texture = ImageTexture.create_from_image(_scale_up(img))
	# 日志
	var lines: Array[String] = []
	lines.append("管线: %s  seed=%d  （%d 个生成器）" % [def.name, seed, def.generators.size()])
	if terrain:
		lines.append("地形: 实体 %d / 空地 %d" % [terrain.count(solid_val), terrain.count(empty_val)])
	if biome_map:
		var bc := {}
		for i in biome_map.indices:
			if i >= 0 and i < biome_map.biomes.size():
				bc[biome_map.biomes[i].name] = bc.get(biome_map.biomes[i].name, 0) + 1
		lines.append("群系: %s" % [bc])
	if not river.is_empty():
		lines.append("河流: %d 段路径（沿梯度入海）" % river.size())
	if not road.is_empty():
		lines.append("道路: %d 段路径（最小生成树连接枢纽）" % road.size())
	lines.append("资源点: %d 个（自动避开地形实体格）" % resources.size())
	var loot_lines: Array[String] = []
	for it in loot:
		loot_lines.append(str(it))
	if not loot_lines.is_empty():
		lines.append("战利品: %s" % ["、".join(loot_lines)])
	_log("\n".join(lines))


## 把路径点画到图上（用于河流/道路合成图）
func _draw_path(img: Image, path: PackedVector2Array, color: Color, radius: int) -> void:
	for p in path:
		var px := int(p.x)
		var py := int(p.y)
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var x := px + dx
				var y := py + dy
				if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
					img.set_pixel(x, y, color)


## —— 散布放置 ——

func _gen_place(seed: int) -> void:
	var def := _selected_def(placement_defs) as PlacementDef
	if def == null:
		_log("请配置 placement_defs")
		return
	var pts := PCGTool.place(def, PCGTool.make_rng(seed))
	var img := PCGTool.points_to_image(pts, Vector2i(int(def.region_size.x), int(def.region_size.y)))
	texture_rect.texture = ImageTexture.create_from_image(_scale_up(img))
	_log("散布: %s\n模式=%s  生成 %d 点" % [def.name, PlacementDef.Mode.keys()[def.mode], pts.size()])


## —— 内容生成 ——

func _gen_content(seed: int) -> void:
	var res := _selected_def(content_defs)
	if res is ContentEvolveDef:
		_gen_evolve(res as ContentEvolveDef, seed)
		return
	var def := res as ContentGenDef
	if def == null:
		_log("请配置 content_defs")
		return
	var items := PCGTool.generate_content(def, PCGTool.make_rng(seed))
	texture_rect.texture = null
	var lines: Array[String] = []
	for it in items:
		lines.append(str(it))
	_log("内容生成: %s（%d 条）\n\n%s" % [def.name, items.size(), "\n".join(lines)])


## —— 内容进化（遗传算法） ——

func _gen_evolve(def: ContentEvolveDef, seed: int) -> void:
	var evo := PCGTool.evolve_content(def, PCGTool.make_rng(seed))
	texture_rect.texture = null
	var lines: Array[String] = []
	lines.append("内容进化: %s（%d 代 遗传算法）\n进化出高适应度组合：" % [def.name, def.generations])
	for item in evo:
		lines.append("  %s  → 强度 %.1f" % [item.name, item.fitness])
	_log("\n".join(lines))


## —— 日志 ——

func _log(msg: String) -> void:
	log_box.text = msg
