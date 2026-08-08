class_name BattleVisualizer
extends RefCounted

## 战斗可视化 —— 把 BattleCell 数据渲染成点阵。
## 所有模式(战斗玩法/纯数值热点)共用同一套显示方式:
##   - 大小   = f(hp): 血越满越大 (min 4 ~ max 16)
##   - 透明度 = f(hp): 血越满越不透明, 血少变淡
##   - 颜色   = 统一色系(青→黄→红 随血量变化, 一眼看出状态)
## 每帧从世界取列, 转成点/大小/颜色数组, 喂给 ECSPointCloud。

var world: ECSWorld
var cloud: ECSPointCloud

func _init(p_world: ECSWorld, p_cloud: ECSPointCloud) -> void:
	world = p_world
	cloud = p_cloud
	if cloud != null:
		cloud.set_color(Color(0.5, 0.9, 0.5))


## 刷新可视化(每帧或隔帧调用)
func refresh() -> void:
	if world == null or cloud == null:
		return
	var rows: PackedInt32Array = world.query_rows(BattleCell, [], [])
	if rows.is_empty():
		cloud.set_points(PackedVector2Array())
		cloud.set_sizes(PackedFloat32Array())
		cloud.set_colors(PackedColorArray())
		return
	var pos_col: PackedVector2Array = world.get_column(BattleCell, &"pos")
	var hp_col: PackedFloat32Array = world.get_column(BattleCell, &"hp")
	var max_col: PackedFloat32Array = world.get_column(BattleCell, &"max_hp")

	var pts := PackedVector2Array()
	var sizes := PackedFloat32Array()
	var cols := PackedColorArray()
	for e in rows:
		if e >= pos_col.size():
			continue
		pts.append(pos_col[e])
		# 大小 = f(hp): 满血26, 残血3(大跨度, 一眼看出状态)
		var ratio := clampf(hp_col[e] / maxf(max_col[e], 1.0), 0.0, 1.0)
		sizes.append(3.0 + ratio * 23.0)
		# 颜色随血量: 青(满)→黄(中)→红(低); 透明度随血量: 满血实心, 残血近乎透明
		var alpha := 0.15 + ratio * 0.85
		if ratio > 0.66:
			cols.append(Color(0.3, 0.95, 0.6, alpha))        # 高血 青绿
		elif ratio > 0.33:
			cols.append(Color(0.98, 0.85, 0.25, alpha))      # 中血 黄
		else:
			cols.append(Color(0.95, 0.3, 0.25, alpha))       # 低血 红
	cloud.set_points(pts)
	cloud.set_sizes(sizes)
	cloud.set_colors(cols)
