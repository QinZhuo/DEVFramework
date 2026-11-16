class_name PopupTextSystem
extends ECSSystem

## 飘字系统 —— 把 PopupTextComponent 映射到**池化的 Label3D**。
##
## 显式契约(不做自动创建):
##   `bind_pool(root, max_count)` 由调用方提供容器节点与池上限; 系统只在池内复用, 池不够就跳过
##   (并通过 `last_dropped` 暴露出来), 不会偷偷 new 节点。
##
## 每帧成本: `query_entities`(1) + `columns_of`(1) + 对**存活飘字**逐个写 4 个属性。
## 对比"每次弹字 new/queue_free": 省掉节点创建/销毁与 SceneTree 增删。

const FIELDS: Array = [&"pos", &"life", &"ttl", &"rise", &"text", &"color"]

var _root: Node3D
var _labels: Array[Label3D] = []
var _font_size := 44
var _billboard := true

## 最近一次同步中"因池不足被跳过"的飘字数(0 = 全部显示)
var last_dropped := 0


## 绑定节点池。必须在 sync 之前调用一次。
func bind_pool(root: Node3D, max_count := 256, font_size := 44) -> void:
	_root = root
	_font_size = font_size
	_ensure(max_count)


func _ensure(n: int) -> void:
	if _root == null:
		return
	while _labels.size() < n:
		var l := Label3D.new()
		l.font_size = _font_size
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED if _billboard else BaseMaterial3D.BILLBOARD_DISABLED
		l.no_depth_test = true
		l.pixel_size = 0.01
		l.visible = false
		_root.add_child(l)
		_labels.append(l)


func pooled_count() -> int:
	return _labels.size()


func required_components() -> Array[Script]:
	return [PopupTextComponent]


func read_components() -> Array[Script]:
	return [PopupTextComponent]


## 触碰节点 → 主线程串行。
func can_run_parallel() -> bool:
	return false


func _run(ctx: ECSSystemContext, delta: float) -> void:
	# 数据侧(寿命/回收) 与 视图侧(Label3D 池) 分开: 前者可在 headless 跑。
	advance(ctx.world, delta)
	sync(ctx.world)


## 数据侧推进: 寿命整列减 + 到期回收(销毁实体)。返回回收数量。
## 与视图分离, 是为了"纯逻辑帧"(headless/服务端)能跑同一套, 不必有 Label3D。
static func advance(world: ECSWorld, delta: float) -> int:
	if world == null or delta <= 0.0:
		return 0
	world.register_component(PopupTextComponent)
	# ① 寿命整列减(1 次跨语言)
	world.batch_apply(PopupTextComponent, [], PopupTextComponent, &"life", 0, 1.0, -delta)
	# ② 到期回收: 原生条件过滤 + 批量销毁
	# ⚠ lambda 按值捕获局部变量 → 用 Array 当接收槽
	var sink: Array = []
	ECSQuery.new(world, PopupTextComponent) \
			.where(&"life").less_or_equal(0.0) \
			.process(func(rows: PackedInt32Array, _c: Dictionary, _w) -> void:
				sink.append(rows)).execute()
	if sink.is_empty():
		return 0
	var rows: PackedInt32Array = sink[0]
	if rows.is_empty():
		return 0
	var ents := world.query_entities(PopupTextComponent)
	var to_kill := PackedInt32Array()
	to_kill.resize(rows.size())
	for i in rows.size():
		var row := int(rows[i])
		to_kill[i] = ents[row] if row >= 0 and row < ents.size() else -1
	world.cmd_destroy_many(to_kill)
	world.cmd_flush()
	return to_kill.size()


## 同步视图。返回实际显示的飘字数。
func sync(world: ECSWorld) -> int:
	last_dropped = 0
	if world == null or _root == null:
		return 0
	world.register_component(PopupTextComponent)
	var ents := world.query_entities(PopupTextComponent)
	var shown := 0
	if not ents.is_empty():
		var cols: Dictionary = world.columns_of(PopupTextComponent, FIELDS)
		if not cols.is_empty():
			var c_pos: PackedVector3Array = cols[&"pos"]
			var c_life: PackedFloat32Array = cols[&"life"]
			var c_ttl: PackedFloat32Array = cols[&"ttl"]
			var c_rise: PackedFloat32Array = cols[&"rise"]
			var c_text: PackedStringArray = cols[&"text"]
			var c_color: PackedColorArray = cols[&"color"]
			var n := mini(ents.size(), mini(c_pos.size(), c_life.size()))
			# 池大小由 bind_pool 决定, 这里**不自动扩容**(超出的计入 last_dropped),
			# 否则"每帧悄悄 new 节点"会退化成无池 —— 与显式绑定的初衷相反。
			for i in n:
				if c_life[i] <= 0.0:
					continue   # 到期(由调用方的 Timer/回收逻辑销毁实体), 这里先不显示
				if shown >= _labels.size():
					last_dropped = n - shown
					break
				var ttl := maxf(c_ttl[i], 0.0001)
				var age := ttl - c_life[i]
				var a := clampf(c_life[i] / ttl, 0.0, 1.0)
				var l := _labels[shown]
				l.text = c_text[i]
				l.position = c_pos[i] + Vector3(0.0, c_rise[i] * age, 0.0)
				var col := c_color[i]
				l.modulate = Color(col.r, col.g, col.b, a)
				l.visible = true
				shown += 1
	# 多余标签隐藏(池复用)
	for i in range(shown, _labels.size()):
		if _labels[i].visible:
			_labels[i].visible = false
	return shown
