extends Control

## 对象池演示：同一批卡片实例被反复复用。
## 「重刷」后每张卡片上的实例号不变，说明没有再 instantiate；HUD 显示池的实时计数。

const CARD := preload("res://Scenes/View/PoolDemoCard.tscn")
const KEY := "PoolDemoCard"
const STEP := 3

@onready var _list: ArrayView = %List
@onready var _stats: Label = %Stats

var _items: Array = []
var _seq := 0


func _ready() -> void:
	## 池化三件套：pool_key + view_scene（顺序无关，但 key 先写少一次无谓解析）+ pool_size
	_list.pool_key = KEY
	_list.pool_size = 6
	_list.view_scene = CARD
	%Add.pressed.connect(_add.bind(STEP))
	%Remove.pressed.connect(_remove.bind(STEP))
	%Refresh.pressed.connect(_refresh)
	%Clear.pressed.connect(_clear)
	_add(6)


func _add(count: int) -> void:
	for i in count:
		_seq += 1
		_items.append(_seq)
	_push()


func _remove(count: int) -> void:
	for i in count:
		if _items.is_empty():
			break
		_items.pop_back()
	_push()


func _refresh() -> void:
	_push()


func _clear() -> void:
	_items.clear()
	_push()


func _push() -> void:
	_list.data = _items
	_update_stats()


func _update_stats() -> void:
	var pool := PoolService.find(KEY)
	if pool == null:
		_stats.text = "池未创建（走编辑器预览？编辑器里一律不池化）"
		return
	var created := pool.created_count
	var reused := pool.reused_count
	var total := created + reused
	var rate := 0.0 if total == 0 else 100.0 * reused / total
	_stats.text = "创建 %d ｜ 借出 %d ｜ 空闲 %d ｜ 复用 %d（命中率 %.0f%%）" % [
		created, pool.in_use_count(), pool.idle_count(), reused, rate]
