class_name BattleSystem
extends ECSSystem

## 吞并战斗系统 —— 核心逻辑(各层共用)。
##
## 负责: 找敌 + 移动 + 攻击判定 + 扣血 + 击杀吞并。
## 每个细胞各自为战: 无阵营, 找最近的任何活细胞攻击, 击杀后由最近活细胞吞并。
## 大小(size)更新由各层的"数值系统"负责(体现实现差异):
##   - 手写脚本层: BattleSizeSystem (GDScript 循环)
##   - 声明规则层: BattleSizeRule (ECSRule)
##   - 原生API层:  BattleSizeNativeSystem (batch)
##
## 注: 本系统是逻辑主体, 各层相同; 数值层体现性能差异。

var spatial: ECSSpatialIndex
var _dead: Array[int] = []
var _frame := 0

var attack_range_factor: float = 1.4
var base_size: float = 8.0
var size_per_hp: float = 0.08
var damage_scale: float = 0.3   # 伤害缩放(降低击杀速度)

func required_components() -> Array[Script]:
	return [BattleCell]

func _run(ctx: ECSSystemContext, delta: float) -> void:
	var w := ctx.world
	_frame += 1
	var rows: PackedInt32Array = w.query_rows(BattleCell, [], [])
	if rows.is_empty():
		return
	if spatial == null:
		spatial = ECSSpatialIndex.new(w, BattleCell, &"pos", 64.0)
	if _frame % 8 == 1:
		spatial.rebuild()

	var pos_col: PackedVector2Array = w.get_column(BattleCell, &"pos")
	var vel_col: PackedVector2Array = w.get_column(BattleCell, &"vel")
	var hp_col: PackedFloat32Array = w.get_column(BattleCell, &"hp")
	var max_col: PackedFloat32Array = w.get_column(BattleCell, &"max_hp")
	var dmg_col: PackedFloat32Array = w.get_column(BattleCell, &"dmg")
	var size_col: PackedFloat32Array = w.get_column(BattleCell, &"size")

	var dmg_frame := 60.0 * delta
	_dead.clear()

	# 单 pass: 移动 + 找敌 + 攻击(各自为战, 无阵营)
	for e in rows:
		var radius := (size_col[e] + 60.0) * attack_range_factor
		var target := spatial.query_cell_nearest(pos_col[e], radius, e)
		if target >= 0:
			var dir := (pos_col[target] - pos_col[e]).normalized()
			vel_col[e] = dir * (40.0 + (100.0 - hp_col[e]) * 0.5)
			var dist := pos_col[e].distance_to(pos_col[target])
			if dist < (size_col[e] + size_col[target]) * attack_range_factor:
				hp_col[target] -= dmg_col[e] * dmg_frame * damage_scale
		else:
			if _frame % 200 == 0:
				# 确定性伪随机: 基于实体id+帧号, 保证三路行为完全一致
				var rs = rand_from_seed(e * 7919 + _frame)
				var rv: int = absi(rs[1])
				var rx: float = ((rv % 2000) / 1000.0) - 1.0
				var ry: float = (((rv / 7) % 2000) / 1000.0) - 1.0
				vel_col[e] = Vector2(rx, ry).normalized() * 30.0
		# 位置积分: pos += vel * delta
		pos_col[e] += vel_col[e] * delta
		if pos_col[e].x < 15 or pos_col[e].x > 1135:
			vel_col[e].x = -vel_col[e].x
		if pos_col[e].y < 15 or pos_col[e].y > 705:
			vel_col[e].y = -vel_col[e].y
		if hp_col[e] <= 0:
			_dead.append(e)

	# 击杀吞并: 死细胞 → 最近的活细胞吸收(各自为战)
	for e in _dead:
		var absorber := spatial.query_cell_nearest(pos_col[e], 300.0, e)
		if absorber >= 0 and hp_col[absorber] > 0 and hp_col[e] <= 0:
			hp_col[absorber] = minf(hp_col[absorber] + max_col[e] * 0.5, max_col[absorber] * 1.5)

	# 写回
	w.set_column(BattleCell, &"pos", pos_col)
	w.set_column(BattleCell, &"vel", vel_col)
	w.set_column(BattleCell, &"hp", hp_col)
	# 击杀销毁: 用 Command Buffer 排队(行号 -> 实体ID), 帧末统一删除,
	# 避免在系统遍历中直接改结构(迭代失效/重入问题)
	for e in _dead:
		var eid := w.entity_of_row(BattleCell, e)
		if eid >= 0:
			w.cmd_destroy(eid)
	_dead.clear()
