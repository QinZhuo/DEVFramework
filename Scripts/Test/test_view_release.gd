extends TestCase

## 视图释放与槽位信号的回归：
## A1 同一节点释放两次时第二次必须无效 —— tween_free 淡出期间节点仍在树内，
##    只看 is_queued_for_deletion() 挡不住，重复 tween_free / 重复归还会让槽位错位。
## A2 OffsetArrayView2D 的场景预置槽位也要连上 visibility_changed，且重复入场不重复连接。


class FadingView extends Node:
	var free_calls := 0

	func tween_free() -> void:
		free_calls += 1


func test_free_view_is_idempotent() -> void:
	var node := Node.new()
	assert_true(ArrayViewTool.free_view(node, null), "首次释放应生效")
	assert_false(ArrayViewTool.free_view(node, null), "已排队的节点不应被再次释放")


func test_fading_view_is_released_once() -> void:
	var view := FadingView.new()
	assert_true(ArrayViewTool.free_view(view, null), "首次释放应触发 tween_free")
	assert_false(ArrayViewTool.free_view(view, null), "淡出中的节点不应被再次释放")
	assert_eq(view.free_calls, 1, "tween_free 只能调用一次")
	view.free()


func test_offset_view_connects_preexisting_slots() -> void:
	var view := OffsetArrayView2D.new()
	var slot := Node2D.new()
	slot.name = "Slot0"
	view.add_child(slot)          # 进树前已存在 ⇒ 不会触发 child_entered_tree
	view._ready()
	assert_true(slot.visibility_changed.is_connected(view._on_visibility_changed),
			"场景预置槽位应连上 visibility_changed")
	view._on_child_entered(slot)  # 重挂父节点会再来一次入场
	assert_true(slot.visibility_changed.is_connected(view._on_visibility_changed),
			"重复入场不应重复连接")
	view.free()
