extends Control
## 分块世界演示 · 确定性无限世界 + 异步生成 + seed 存档
##
## 演示 ChunkedWorld：同一 seed 下任意 (cx, cy) chunk 必然可复现，
## 支持同步/后台线程异步生成，seed 可通过 SaveTool 存读取档复现。

@export var grid_defs: Array[Resource] = []

@onready var texture_rect: TextureRect = %TextureRect
@onready var algo_option: OptionButton = %AlgoOption
@onready var radius_spin: SpinBox = %RadiusSpin
@onready var seed_spin: SpinBox = %SeedSpin
@onready var async_check: CheckButton = %AsyncCheck
@onready var log_box: RichTextLabel = %LogBox

const SAVE_PATH := "user://chunk_demo_save.json"

var _world := ChunkedWorld.new()


func _ready() -> void:
	algo_option.item_selected.connect(func(_i: int) -> void: _rebuild())
	radius_spin.value_changed.connect(func(_v: float) -> void: _rebuild())
	seed_spin.value_changed.connect(func(_v: float) -> void: _rebuild())
	async_check.toggled.connect(func(_on: bool) -> void: _rebuild())
	for i in grid_defs.size():
		var d: Resource = grid_defs[i]
		var label := d.resource_path.get_file().get_basename() if d and not d.resource_path.is_empty() else ("资源%d" % i)
		algo_option.add_item(label, i)
	_rebuild()


func _selected_def() -> GridGenDef:
	if algo_option.selected < 0 or algo_option.selected >= grid_defs.size():
		return null
	return grid_defs[algo_option.selected] as GridGenDef


func _on_regenerate_pressed() -> void:
	_rebuild()


func _rebuild() -> void:
	_log("生成中...")
	_build_async()


func _build_async() -> void:
	var def := _selected_def()
	if def == null:
		_log("请配置 grid_defs")
		return
	var radius := int(radius_spin.value)
	var use_async := async_check.button_pressed
	_world = ChunkedWorld.new()
	_world.seed_base = int(seed_spin.value)
	_world.grid_def = def
	_world.chunk_size = 16
	var t := Time.get_ticks_msec()
	if use_async:
		# 后台线程逐个生成 chunk，全部完成后一起渲染（不卡主线程）
		for cy in range(-radius, radius + 1):
			for cx in range(-radius, radius + 1):
				var g := await _world.generate_chunk_async(cx, cy)
				if not is_inside_tree():
					return
				_world.add_chunk(cx, cy, g)
	else:
		for cy in range(-radius, radius + 1):
			for cx in range(-radius, radius + 1):
				_world.get_chunk(cx, cy)
	var ms := Time.get_ticks_msec() - t
	var img := _render_world(_world, def, -radius, -radius, radius, radius)
	if not is_inside_tree():
		return
	texture_rect.texture = ImageTexture.create_from_image(img)
	var n := (radius * 2 + 1) * (radius * 2 + 1)
	_log("分块世界: %d 个 chunk（%d x %d 像素，chunk=16）  耗时 %d ms\nseed=%d  %s" % [
		n, img.get_width(), img.get_height(), ms, _world.seed_base,
		"异步(后台线程)" if use_async else "同步",
	])


## 把 chunk 区域拼合成一张图，并画出 chunk 边界
func _render_world(world: ChunkedWorld, def: GridGenDef, cx0: int, cy0: int, cx1: int, cy1: int) -> Image:
	var cs := world.chunk_size
	var w := (cx1 - cx0 + 1) * cs
	var h := (cy1 - cy0 + 1) * cs
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var palette := {}
	if def and def.type == GridGenDef.Type.WFC and def.tile_set:
		for i in def.tile_set.tiles.size():
			palette[i] = def.tile_set.tiles[i].color
	else:
		palette[def.solid_value] = Color(0.92, 0.95, 0.98)
		palette[def.empty_value] = Color(0.13, 0.15, 0.18)
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			var g := world.get_chunk(cx, cy)
			for y in cs:
				for x in cs:
					img.set_pixel((cx - cx0) * cs + x, (cy - cy0) * cs + y, palette.get(g.get_cell(x, y), Color.BLACK))
	# chunk 边界线（暗色）
	var border := Color(0.05, 0.05, 0.08)
	for i in range(cs, w, cs):
		for y in h:
			img.set_pixel(i, y, border)
	for j in range(cs, h, cs):
		for x in w:
			img.set_pixel(x, j, border)
	return img


## —— 存档 ——

func _on_save_pressed() -> void:
	var err := SaveTool.save_data(SAVE_PATH, {"seed": int(seed_spin.value), "radius": int(radius_spin.value)}, SaveTool.Mode.JSON)
	_log("已保存: seed=%d radius=%d  err=%d" % [int(seed_spin.value), int(radius_spin.value), err])


func _on_load_pressed() -> void:
	var data = SaveTool.load_data(SAVE_PATH, SaveTool.Mode.JSON)
	if data == null or data.is_empty():
		_log("无存档（%s）" % SAVE_PATH)
		return
	seed_spin.value = data.get("seed", 0)
	radius_spin.value = data.get("radius", 2)
	_log("已加载存档: seed=%d radius=%d" % [int(seed_spin.value), int(radius_spin.value)])


func _log(msg: String) -> void:
	log_box.text = msg
