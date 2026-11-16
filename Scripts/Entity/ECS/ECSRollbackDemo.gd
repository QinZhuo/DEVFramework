extends Node2D

## 确定性 / 回滚样例(联机 lockstep、格斗 rollback 的最小验证):
##
## 1) **确定性**: 同样的初始状态 + 同样的输入序列, 两个独立世界跑 120 tick 后
##    逐字段比较必须**完全相等**(snapshot_diff 为空)。这是联机的前提。
## 2) **回滚**: 存档 → 继续跑 → 用存档恢复出全新世界, 必须与存档逐字段相等。
## 3) **差分带宽**: 同一件事用 snapshot_diff 只报变化的行, 对比全量存档的行数。
##
## 操作: R = 重跑  空格 = 暂停/继续自动重跑

const Unit := preload("res://Scripts/Entity/ECS/ECSDemoMoveComponent.gd")
const DT := 1.0 / 60.0

@export var unit_count := 500
@export var ticks := 120

var _hud: Label = null
var _report: Array[String] = []


func _ready() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_font_size_override("font_size", 15)
	layer.add_child(_hud)
	_run()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if (event as InputEventKey).keycode in [KEY_R, KEY_SPACE]:
			_run()


func _run() -> void:
	_report.clear()
	# 用"固定公式"初始化, 不用 randf: 随机数会引入不确定性, 那样测的就不是引擎了
	var a := _make_world()
	var snap0: Dictionary = a.serialize()
	for i in ticks:
		_step(a)
	var snap_a: Dictionary = a.serialize()

	var b := _make_world()
	for i in ticks:
		_step(b)
	var snap_b: Dictionary = b.serialize()

	var det_ok: bool = _same_values(snap_a, snap_b)
	_report.append("确定性(两个独立世界跑 %d tick): %s" % [ticks, "PASS" if det_ok else "FAIL"])

	# 回滚: 用 snap0 重建一个全新世界, 必须与 snap0 的**值**完全一致
	# (实体 id 会重新分配, 所以比的是列值而不是 id —— 这也是 rollback 的真实语义)
	var r := ECSWorld.new(false)
	r.register_component(Unit)
	r.deserialize(snap0)
	var rb_ok: bool = _same_values(snap0, r.serialize())
	_report.append("回滚(存档 → 重建): %s" % ("PASS" if rb_ok else "FAIL"))

	# 差分 vs 全量: 只报变化行
	var diff: Dictionary = a.snapshot_diff(snap0, snap_a)
	var changed_rows := 0
	for cn in diff:
		var spec: Dictionary = diff[cn]
		if spec.get("structural", false):
			continue
		for f in spec:
			changed_rows += (spec[f]["rows"] as PackedInt32Array).size()
	var total_cells := unit_count * 2   # pos + vel 两个字段
	_report.append("差分: 变化 %d 行 / 全量 %d 行 (%.0f%%)" % [
		changed_rows, total_cells, 100.0 * float(changed_rows) / maxf(float(total_cells), 1.0)])

	_report.append("世界: %d 实体 / %d 个组件列" % [a.count(Unit), int(_total_cols(snap0))])

	_hud.text = "确定性 / 回滚样例   (R 或 空格 重跑)\n\n" + "\n".join(PackedStringArray(_report))


## 只比"值"(组件名 + 每字段的整条列), 不比实体 id —— deserialize 会重新分配 id。
func _same_values(a: Dictionary, b: Dictionary) -> bool:
	var ac: Array = a.get("components", [])
	var bc: Array = b.get("components", [])
	if ac.size() != bc.size():
		return false
	for i in ac.size():
		var ca: Dictionary = ac[i]
		var cb: Dictionary = bc[i]
		if ca.get("name") != cb.get("name"):
			return false
		var fa: Dictionary = ca.get("columns", {})
		var fb: Dictionary = cb.get("columns", {})
		if fa.size() != fb.size():
			return false
		for f in fa:
			if fa[f] != fb.get(f):
				return false
	return true


func _total_cols(snap: Dictionary) -> int:
	var n := 0
	for cd in snap.get("components", []):
		n += (cd.get("columns", {}) as Dictionary).size()
	return n


func _make_world() -> ECSWorld:
	var w := ECSWorld.new(false)
	w.register_component(Unit)
	var pf := w.create_prefab()
	w.prefab_add(pf, Unit, {})
	w.instantiate(pf, unit_count)
	var c := w.columns_of(Unit, [&"pos", &"vel"])
	var pos: PackedVector2Array = c[&"pos"]
	var vel: PackedVector2Array = c[&"vel"]
	for i in pos.size():
		# 确定性伪随机: 只依赖 i(不用 randf), 两端必然一致
		pos[i] = Vector2(float((i * 37) % 800), float((i * 53) % 600))
		vel[i] = Vector2(float((i % 7) - 3), float((i % 5) - 2)) * 10.0
	w.set_columns_of(Unit, {&"pos": pos, &"vel": vel})
	return w


func _step(w: ECSWorld) -> void:
	var c := w.columns_of(Unit, [&"pos", &"vel"])
	var pos: PackedVector2Array = c[&"pos"]
	var vel: PackedVector2Array = c[&"vel"]
	for i in pos.size():
		pos[i] += vel[i] * DT
	w.set_columns_of(Unit, {&"pos": pos})
