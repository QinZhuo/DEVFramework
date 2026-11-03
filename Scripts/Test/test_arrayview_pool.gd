extends TestCase

## 对象池 × 数组视图集成（必须游戏进程：编辑器下 resolve_pool 一律返回 null，不池化）。
##
## 锁定的是"池真的省下了 instantiate"这件事——只测 Pool 本身证明不了视图接线正确：
## 1) 同数量重刷复用同一批实例，created_count 不再增长；
## 2) 空 pool_key 时不池化，节点重建；
## 3) pool_size 变成预热数量 + 空闲上限。

const KEY := "test_arrayview_pool"
const KEY_SIZE := "test_arrayview_pool_size"
const KEY_HIDE := "test_arrayview_pool_hide"


func needs_game_process() -> bool:
	return true


func cleanup() -> void:
	for v in _views:
		if is_instance_valid(v):
			v.free()
	_views.clear()
	for k: String in [KEY, KEY_SIZE, KEY_HIDE]:
		PoolService.remove(k)


var _views: Array[Node] = []


## 最小视图场景：根节点自带 `data` 属性即可被 rebind
func _scene() -> PackedScene:
	var card := Control.new()
	card.name = "Card"
	var packed := PackedScene.new()
	packed.pack(card)
	card.free()
	return packed


func _new_view(key: String) -> ArrayView:
	var view := ArrayView.new()
	view.view_scene = _scene()
	view.pool_key = key
	## 进树：FlowContainer 的排序与尺寸依赖场景树
	Engine.get_main_loop().root.add_child(view)
	_views.append(view)
	return view


func _ids(view: ArrayView) -> Array:
	var out := []
	for v in view.views:
		out.append(v.get_instance_id() if is_instance_valid(v) else -1)
	out.sort()
	return out


func test_refresh_reuses_the_same_instances() -> void:
	var view := _new_view(KEY)
	view.data = [1, 2, 3]
	var first := _ids(view)
	assert_eq(first.size(), 3, "应建出 3 个视图")

	var pool := PoolService.find(KEY)
	assert_true(pool != null, "填了 pool_key 应注册出池")
	assert_eq(pool.created_count, 3, "首轮现场创建 3 个")

	view.data = [4, 5, 6]
	assert_eq(_ids(view), first, "同数量重刷应复用同一批实例")
	assert_eq(pool.created_count, 3, "复用不应再计入创建")
	assert_eq(pool.reused_count, 3, "三个视图都应命中复用")


func test_without_pool_key_rebuilds() -> void:
	var view := _new_view("")
	view.data = [1]
	var before := view.get_view(0)
	view.data = [2]
	assert_true(view.get_view(0) != before, "空 pool_key 时应重建节点")
	assert_true(PoolService.find("") == null, "空 key 不建池")


func test_pool_size_prewarms_and_caps_idle() -> void:
	var view := _new_view(KEY_SIZE)
	view.pool_size = 4
	view.data = [1]

	var pool := PoolService.find(KEY_SIZE)
	assert_eq(pool.max_idle, 4, "pool_size 应成为空闲上限")
	assert_eq(pool.created_count, 4, "首次使用前预建 4 个")
	assert_eq(pool.idle_count(), 3, "用掉一个后剩 3 个空闲")


func test_returned_view_is_hidden() -> void:
	var view := _new_view(KEY_HIDE)
	view.data = [1]
	var card := view.get_view(0) as Control
	assert_true(card.visible, "在用时可见")

	view.data = []
	assert_false(card.visible, "归还池的实例必须隐藏，否则会以旧变换留在场景里")
	assert_true(card.get_parent() != null, "归还后仍挂在池的容器下（不脱离场景树）")
