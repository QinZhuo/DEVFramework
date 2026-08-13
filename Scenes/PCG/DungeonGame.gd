extends Node2D
## 地牢探索小游戏 · PCG 生成地牢
##
## PCG 生成地牢（BSP/模板拼接/细胞洞穴/迷宫随机选），回合制打怪：
##   - 方向键移动，撞墙阻挡，走向怪物=攻击
##   - 怪物每回合向玩家靠近一格，相邻则攻击
##   - 三种怪物：普通(蓝)/精英(紫)/首领(红，每5层)，属性随层数上升
##   - 击杀掉落装备（词缀命名+攻击加成），可拾取换武器
##   - 经验/等级成长：击杀加经验，升级提升生命/攻击
##   - 金币/药水拾取，到达出口进入下一层（难度随层数上升）
## 改 seed 换新地牢，seed 可复现。

@export var grid_defs: Array[Resource] = []
@export var tile_size := 12
@export var max_hp := 100
@export var attack := 25

enum MonsterKind { NORMAL, ELITE, BOSS }

@onready var map_sprite: Sprite2D = %MapSprite
@onready var nav_region: NavigationRegion2D = %NavRegion
@onready var player_rect: ColorRect = %Player
@onready var items_layer: Node2D = %Items
@onready var hud_label: Label = %HudLabel
@onready var seed_spin: SpinBox = %SeedSpin
@onready var terrain_option: OptionButton = %TerrainOption
@onready var auto_check: CheckButton = %AutoCheck
@onready var log_box: RichTextLabel = %LogBox

var grid: GeneratedGrid
var grid_def: GridGenDef
var _astar: AStarGrid2D
## 当前地形配置（GridGenDef 或 TemplateStitchDef，统一取 solid/empty）
var cur_terrain: Resource
var player_pos := Vector2i.ZERO
var exit_pos := Vector2i(-1, -1)
var monsters := {}
var monster_nodes := {}
var equipment := {}
var coins := {}
var potions := {}
var gold := 0
var player_hp := 100
var exp := 0
## 层数（决定怪物/装备强度）
var depth := 1
## 角色等级（经验成长）
var level := 1
var weapon := {"name": "木剑", "attack": 0}
var map_origin := Vector2.ZERO
var game_over := false
## AI 自动游玩：自动寻路捡物/打怪/下楼（可观赏）
var _ai_timer := 0.0


func _ready() -> void:
	terrain_option.add_item("随机")
	for d in grid_defs:
		var label := _terrain_name(d)
		terrain_option.add_item(label)
	terrain_option.item_selected.connect(func(_i: int) -> void:
		depth = 1
		gold = 0
		exp = 0
		level = 1
		player_hp = max_hp
		attack = 25
		weapon = {"name": "木剑", "attack": 0}
		_generate()
	)
	seed_spin.value_changed.connect(func(_v: float) -> void:
		depth = 1
		gold = 0
		exp = 0
		level = 1
		player_hp = max_hp
		attack = 25
		weapon = {"name": "木剑", "attack": 0}
		_generate()
	)
	_generate.call_deferred()


## 地形类型名（用于选择列表/介绍）
func _terrain_name(def: Resource) -> String:
	if def is TemplateStitchDef:
		return "模板拼接"
	var g := def as GridGenDef
	if g:
		match g.type:
			GridGenDef.Type.BSP_ROOMS:
				return "BSP 房间"
			GridGenDef.Type.CELLULAR:
				return "细胞洞穴"
			GridGenDef.Type.MAZE:
				return "Prim 迷宫"
	return def.resource_path.get_file().get_basename()


## 地形介绍：名称 + 规则一句话（关键信息）
func _terrain_info(def: Resource) -> Dictionary:
	if def is TemplateStitchDef:
		return {"name": "模板拼接", "rule": "手作模板（房间/大厅/宝藏室）随机放置 + 走廊连接，有手作关卡感"}
	var g := def as GridGenDef
	if g:
		match g.type:
			GridGenDef.Type.BSP_ROOMS:
				return {"name": "BSP 房间", "rule": "二叉树分割→叶子生成矩形房间→L 型走廊全连通，规整地牢"}
			GridGenDef.Type.CELLULAR:
				return {"name": "细胞洞穴", "rule": "随机填充 42% 墙 → Rogue 4-5 规则 4 轮平滑，有机洞穴网络"}
			GridGenDef.Type.MAZE:
				return {"name": "Prim 迷宫", "rule": "Prim 生成树 + 少量环路，单格宽通道密集迷宫"}
	return {"name": def.resource_path.get_file().get_basename(), "rule": ""}


func _pick_terrain_def(defs: Array) -> Resource:
	var selected := terrain_option.selected
	if selected <= 0:
		return defs.pick_random() as Resource
	var idx := selected - 1
	if idx >= 0 and idx < defs.size():
		return defs[idx] as Resource
	return defs.pick_random() as Resource


func _exp_to_next() -> int:
	return level * 50


func _solid() -> int:
	if cur_terrain is GridGenDef:
		return (cur_terrain as GridGenDef).solid_value
	if cur_terrain is TemplateStitchDef:
		return (cur_terrain as TemplateStitchDef).solid_value
	return 1


func _empty() -> int:
	if cur_terrain is GridGenDef:
		return (cur_terrain as GridGenDef).empty_value
	if cur_terrain is TemplateStitchDef:
		return (cur_terrain as TemplateStitchDef).empty_value
	return 0


func _total_attack() -> int:
	return attack + weapon.attack


func _generate() -> void:
	var defs: Array = []
	for d in grid_defs:
		if d is GridGenDef or d is TemplateStitchDef:
			defs.append(d)
	if defs.is_empty():
		_log("请配置 grid_defs")
		return
	var raw_def: Resource = _pick_terrain_def(defs)
	cur_terrain = raw_def
	if raw_def is TemplateStitchDef:
		grid_def = null
		grid = PCGTool.generate_template_stitch(raw_def as TemplateStitchDef, PCGTool.make_rng(int(seed_spin.value) + depth))
	elif raw_def is GridGenDef:
		grid_def = raw_def as GridGenDef
		grid = PCGTool.generate_grid(grid_def, PCGTool.make_rng(int(seed_spin.value) + depth))
	else:
		return
	for child in items_layer.get_children():
		child.queue_free()
	monsters.clear()
	monster_nodes.clear()
	equipment.clear()
	coins.clear()
	potions.clear()
	game_over = false
	_show_map()
	_build_navigation()
	_place_entities()
	player_rect.visible = true
	_gold_ui()
	var info := _terrain_info(raw_def)
	var solid_n := grid.count(_solid())
	var empty_n := grid.cells.size() - solid_n
	var comps := grid.components(_empty()).size()
	_log("第 %d 层：%s\n【%s】%s\n地图：%d×%d，实体 %d／空地 %d，连通域 %d\n方向键移动（走向怪物=攻击），捡 ●金币 ／ ♥药水 ／ ★装备，到 ★出口下楼" % [
		depth, info.name, info.name, info.rule,
		grid.width, grid.height, solid_n, empty_n, comps,
	])


func _show_map() -> void:
	var img := PCGTool.grid_to_image(grid, {
		_solid(): Color(0.16, 0.18, 0.22),
		_empty(): Color(0.8, 0.82, 0.85),
	})
	img.resize(grid.width * tile_size, grid.height * tile_size, Image.INTERPOLATE_NEAREST)
	map_sprite.texture = ImageTexture.create_from_image(img)
	map_origin = Vector2(-grid.width * tile_size / 2.0, -grid.height * tile_size / 2.0)
	map_sprite.position = map_origin


func _place_entities() -> void:
	var start := _find_start()
	player_pos = start
	player_rect.size = Vector2(tile_size, tile_size)
	player_rect.position = _grid_to_world(start)
	exit_pos = _find_farthest(start)
	_add_marker(exit_pos, Color(0.95, 0.8, 0.2), tile_size)
	var rng := PCGTool.make_rng(int(seed_spin.value) + depth + 2)
	_place_pickups(rng, start, 12, coins, Color(1.0, 0.8, 0.25), tile_size / 2)
	_place_pickups(rng, start, 4, potions, Color(0.95, 0.5, 0.7), tile_size / 2)
	var count := 3 + depth * 2
	for i in count:
		var p := _find_walkable_away(rng, start, 8)
		if p.x < 0:
			continue
		var kind := MonsterKind.NORMAL
		if depth % 5 == 0 and i == 0:
			kind = MonsterKind.BOSS
		elif rng.randf() < 0.2:
			kind = MonsterKind.ELITE
		var m := _monster_stats(kind)
		monsters[p] = m
		monster_nodes[p] = _add_marker(p, _monster_color(kind), tile_size)


func _monster_stats(kind: int) -> Dictionary:
	match kind:
		MonsterKind.ELITE:
			return {"hp": 80 + depth * 25, "max_hp": 80 + depth * 25, "dmg": 20, "exp": 25, "kind": kind}
		MonsterKind.BOSS:
			return {"hp": 200 + depth * 50, "max_hp": 200 + depth * 50, "dmg": 30, "exp": 100, "kind": kind}
		_:
			return {"hp": 40 + depth * 15, "max_hp": 40 + depth * 15, "dmg": 12, "exp": 10, "kind": kind}


func _monster_color(kind: int) -> Color:
	match kind:
		MonsterKind.ELITE:
			return Color(0.6, 0.35, 0.8)
		MonsterKind.BOSS:
			return Color(0.85, 0.25, 0.25)
		_:
			return Color(0.3, 0.45, 0.85)


func _place_pickups(rng: RandomNumberGenerator, start: Vector2i, target: int, store: Dictionary, color: Color, size: int) -> void:
	var count := 0
	for attempt in 4000:
		if count >= target:
			break
		var p := Vector2i(rng.randi_range(1, grid.width - 2), rng.randi_range(1, grid.height - 2))
		if grid.get_cell(p.x, p.y, -1) == _solid() or p == start or p == exit_pos \
				or coins.has(p) or potions.has(p) or monsters.has(p):
			continue
		store[p] = true
		_add_marker(p, color, size)
		count += 1


func _find_walkable_away(rng: RandomNumberGenerator, start: Vector2i, min_dist: int) -> Vector2i:
	for attempt in 60:
		var p := Vector2i(rng.randi_range(1, grid.width - 2), rng.randi_range(1, grid.height - 2))
		if grid.get_cell(p.x, p.y, -1) != _solid() and p != exit_pos \
				and not monsters.has(p) and absi(p.x - start.x) + absi(p.y - start.y) >= min_dist:
			return p
	return Vector2i(-1, -1)


## 找最大可走连通域中的一格作为出生点（避免出生在孤立小空间被困）
func _find_start() -> Vector2i:
	var visited := {}
	var best_start := Vector2i.ZERO
	var best_size := 0
	for y in grid.height:
		for x in grid.width:
			var p := Vector2i(x, y)
			if visited.has(p) or grid.get_cell(x, y) == _solid():
				continue
			var comp := [p]
			visited[p] = true
			var queue: Array = [p]
			while not queue.is_empty():
				var cur: Vector2i = queue.pop_back()
				for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var np: Vector2i = cur + dir
					if visited.has(np) or not grid.in_bounds(np.x, np.y) or grid.get_cell(np.x, np.y) == _solid():
						continue
					visited[np] = true
					comp.append(np)
					queue.append(np)
			if comp.size() > best_size:
				best_size = comp.size()
				best_start = p
	return best_start


func _find_farthest(start: Vector2i) -> Vector2i:
	var visited := {}
	var queue: Array = [[start, 0]]
	visited[start] = true
	var far := start
	var far_d := 0
	while not queue.is_empty():
		var cur: Array = queue.pop_front()
		var p: Vector2i = cur[0]
		var d: int = cur[1]
		if d > far_d:
			far_d = d
			far = p
		for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var np: Vector2i = p + dir
			if not grid.in_bounds(np.x, np.y):
				continue
			if not visited.has(np) and grid.get_cell(np.x, np.y, -1) != _solid():
				visited[np] = true
				queue.append([np, d + 1])
	return far


func _add_marker(p: Vector2i, color: Color, size: int) -> ColorRect:
	var c := ColorRect.new()
	c.color = color
	c.size = Vector2(size, size)
	c.position = _grid_to_world(p) + Vector2((tile_size - size) / 2.0, (tile_size - size) / 2.0)
	items_layer.add_child(c)
	return c


func _grid_to_world(p: Vector2i) -> Vector2:
	return map_origin + Vector2(p.x * tile_size, p.y * tile_size)


func _world_to_grid(pos: Vector2) -> Vector2i:
	var local := pos - map_origin
	return Vector2i(floori(local.x / tile_size), floori(local.y / tile_size))


## NavigationServer 路径点是连续坐标，落在格边界时取整会偏到相邻墙格，
## 统一校正到最近的合法可走格（导航网格边缘防越界）
func _snap_walkable(p: Vector2i) -> Vector2i:
	if grid.in_bounds(p.x, p.y) and grid.get_cell(p.x, p.y, -1) != _solid():
		return p
	var best := p
	var best_d := INF
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var np := p + Vector2i(dx, dy)
			if grid.in_bounds(np.x, np.y) and grid.get_cell(np.x, np.y, -1) != _solid():
				var d := Vector2(dx, dy).length_squared()
				if d < best_d:
					best_d = d
					best = np
	return best


## 用 Godot 自带 Navigation 构建导航网格（项目侧 NavBridgeTool 桥接 PCG 栅格 → NavigationServer 寻路）
func _build_navigation() -> void:
	NavBridgeTool.setup_navigation_2d(nav_region, grid, _empty(), tile_size, tile_size * 0.1, map_origin, tile_size * 0.4)
	_astar = NavBridgeTool.grid_to_astar_grid(grid, _empty(), Vector2(tile_size, tile_size))


## 回合制格子寻路：Godot 自带 AStarGrid2D 逐格寻路（优化路径点稀疏、落格边界会抖动，格游用 AStar 最稳）
func _next_step(from: Vector2i, to: Vector2i) -> Vector2i:
	if _astar == null or from == to:
		return from
	var path := _astar.get_id_path(from, to)
	if path.size() < 2:
		return from
	return path[1]


## —— 玩家回合 ——

func _process(delta: float) -> void:
	if grid == null or game_over:
		return
	if auto_check.button_pressed:
		# AI 自动游玩：定时间隔决策一步，然后怪物回合
		_ai_timer += delta
		if _ai_timer >= 0.2:
			_ai_timer = 0.0
			_ai_step()
			if game_over:
				return
			_monster_turn()
		return
	var dir := Vector2i.ZERO
	if Input.is_action_pressed("ui_left"):
		dir.x = -1
	elif Input.is_action_pressed("ui_right"):
		dir.x = 1
	if Input.is_action_pressed("ui_up"):
		dir.y = -1
	elif Input.is_action_pressed("ui_down"):
		dir.y = 1
	if dir == Vector2i.ZERO:
		return
	var target := player_pos + dir
	if grid.get_cell(target.x, target.y, -1) == _solid():
		return
	if monsters.has(target):
		_attack_monster(target)
	else:
		player_pos = target
		player_rect.position = _grid_to_world(player_pos)
		_pickup()
		_check_exit()
	if game_over:
		return
	_monster_turn()


## —— AI 自动游玩 ——

## AI 一步：相邻怪优先攻击 → 否则走向最近可捡目标（金币/药水/装备）→ 否则走向出口
func _ai_step() -> void:
	# 相邻怪攻击
	for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var np: Vector2i = player_pos + dir
		if monsters.has(np):
			_attack_monster(np)
			return
	# 找最近可捡目标
	var best := Vector2i(-1, -1)
	var best_d := INF
	for p in coins.keys():
		var d: float = (p as Vector2i).distance_squared_to(player_pos)
		if d < best_d:
			best_d = d
			best = p
	for p in potions.keys():
		var d: float = (p as Vector2i).distance_squared_to(player_pos)
		if d < best_d:
			best_d = d
			best = p
	for p in equipment.keys():
		var d: float = (p as Vector2i).distance_squared_to(player_pos)
		if d < best_d:
			best_d = d
			best = p
	var target := best if best.x >= 0 else exit_pos
	if target.x < 0:
		return
	var step := _next_step(player_pos, target)
	if step == player_pos:
		return
	if monsters.has(step):
		_attack_monster(step)
	else:
		player_pos = step
		player_rect.position = _grid_to_world(step)
		_pickup()
		_check_exit()


func _attack_monster(target: Vector2i) -> void:
	if not monsters.has(target):
		return
	var m: Dictionary = monsters[target]
	m.hp -= _total_attack()
	if m.hp <= 0:
		monsters.erase(target)
		if monster_nodes.has(target):
			monster_nodes[target].queue_free()
			monster_nodes.erase(target)
		var kind_name: String = ["普通", "精英", "首领"][m.kind]
		_log("击败%s怪物！（+%d 经验）" % [kind_name, m.exp])
		_gain_exp(m.exp)
		_drop_equipment(target, m.kind)
	else:
		monsters[target] = m
		_log("攻击怪物（剩余 HP %d/%d）" % [m.hp, m.max_hp])


func _gain_exp(amount: int) -> void:
	exp += amount
	while exp >= _exp_to_next():
		exp -= _exp_to_next()
		level += 1
		max_hp += 15
		player_hp = max_hp
		attack += 3
		_log("升级！Lv.%d（生命+15，攻击+3）" % level)
	_gold_ui()


func _drop_equipment(target: Vector2i, kind: int) -> void:
	if equipment.has(target):
		return
	# 掉落率：首领必掉，精英 50%，普通 25%；用怪物位置独立播种，每只怪判定独立
	var rng := PCGTool.make_rng(int(seed_spin.value) + target.x * 131 + target.y * 17 + kind * 7)
	var rate := 1.0 if kind == MonsterKind.BOSS else (0.5 if kind == MonsterKind.ELITE else 0.25)
	if rng.randf() >= rate:
		return
	var bonus := _gen_equipment_bonus(kind, target)
	var eq := {"name": _gen_equipment_name(target), "attack": bonus}
	equipment[target] = eq
	_add_marker(target, Color(1.0, 0.85, 0.15), tile_size)
	_log("掉落装备：%s（攻击 +%d）！" % [eq.name, eq.attack])


func _gen_equipment_bonus(kind: int, target: Vector2i) -> int:
	var base := 3 if kind == MonsterKind.NORMAL else (6 if kind == MonsterKind.ELITE else 12)
	var rng := PCGTool.make_rng(int(seed_spin.value) + depth * 3 + kind + target.x + target.y)
	return base + rng.randi_range(0, 3 + depth / 2)


func _gen_equipment_name(target: Vector2i) -> String:
	var bases := PackedStringArray(["长剑", "战斧", "法杖", "匕首", "重锤", "长弓"])
	var prefixes := PackedStringArray(["锋利", "烈焰", "冰霜", "雷霆", "暗影", "神圣"])
	var rng := PCGTool.make_rng(int(seed_spin.value) + depth * 5 + target.x * 7 + target.y)
	return prefixes[rng.randi_range(0, prefixes.size() - 1)] + bases[rng.randi_range(0, bases.size() - 1)]


## —— 怪物回合 ——

func _monster_turn() -> void:
	var keys: Array = monsters.keys()
	for pos in keys:
		if not monsters.has(pos):
			continue
		var m: Dictionary = monsters[pos]
		var dir := _towards(pos)
		if dir == Vector2i.ZERO:
			continue
		var target: Vector2i = pos + dir
		if target == player_pos:
			player_hp -= m.dmg
			_gold_ui()
			_log("怪物攻击你！（-%d HP）HP %d/%d" % [m.dmg, player_hp, max_hp])
			if player_hp <= 0:
				_game_over()
				return
		elif grid.get_cell(target.x, target.y, -1) != _solid() \
				and not monsters.has(target) and target != exit_pos and target != player_pos:
			monsters.erase(pos)
			monsters[target] = m
			monster_nodes[target] = monster_nodes[pos]
			monster_nodes.erase(pos)
			monster_nodes[target].position = _grid_to_world(target)


func _towards(pos: Vector2i) -> Vector2i:
	var best := Vector2i.ZERO
	var best_d := player_pos.distance_squared_to(pos)
	for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var np: Vector2i = pos + dir
		if grid.get_cell(np.x, np.y, -1) == _solid():
			continue
		var d := player_pos.distance_squared_to(np)
		if d < best_d:
			best_d = d
			best = dir
	return best


## —— 拾取 / 出口 / 结束 ——

func _pickup() -> void:
	if coins.has(player_pos):
		coins.erase(player_pos)
		gold += 1
		_gold_ui()
		_log("拾取金币！共 %d" % gold)
	if potions.has(player_pos):
		potions.erase(player_pos)
		player_hp = mini(player_hp + 30, max_hp)
		_gold_ui()
		_log("喝下药水！HP %d/%d" % [player_hp, max_hp])
	if equipment.has(player_pos):
		var eq: Dictionary = equipment[player_pos]
		equipment.erase(player_pos)
		var old := weapon
		weapon = eq
		_gold_ui()
		_log("装备 %s（攻击 +%d），替换 %s（+%d）" % [eq.name, eq.attack, old.name, old.attack])


func _check_exit() -> void:
	if player_pos == exit_pos:
		depth += 1
		_gold_ui()
		_generate()
		_log("进入第 %d 层！（HP %d 金币 %d Lv.%d）" % [depth, player_hp, gold, level])


func _game_over() -> void:
	game_over = true
	_log("你死了！第 %d 层，金币 %d，Lv.%d。改 seed 或重新生成再战。" % [depth, gold, level])


func _gold_ui() -> void:
	hud_label.text = "HP %d/%d ｜ 金币 %d ｜ 层 %d ｜ Lv.%d ｜ 攻 %d" % [
		player_hp, max_hp, gold, depth, level, _total_attack(),
	]


func _log(msg: String) -> void:
	log_box.text = msg


