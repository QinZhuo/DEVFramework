extends TestCase

## 对象池契约回归（纯逻辑，编辑器进程即可）。
##
## 锁定的都是「错了不会崩、只会静默出错」的语义：
## 1) 归还/取出幂等：重复归还、非本池实例一律忽略；
## 2) 生命周期钩子只有 on_pool_get / on_pool_return（on_pool_push 是已废弃的旧名）；
## 3) max_idle / prewarm 的实际效果；
## 4) 被外部 free 的借出实例不会永久占着 in_use 计数；
## 5) 注册表按 key 隔离，含 / 的 key 也要能建容器。

const KEY_A := "test_pool_a"
const KEY_B := "test_pool_b"
const KEY_BAD := "test/bad:key"


## 假视图：三个钩子都实现，用来证明池只调 on_pool_return
class _FakeView extends Node:
	var hooks: Array[StringName] = []

	func on_pool_get() -> void:
		hooks.append(&"get")

	func on_pool_return() -> void:
		hooks.append(&"return")

	func on_pool_push() -> void:
		hooks.append(&"push")


var _nodes: Array[Node] = []


func cleanup() -> void:
	PoolService.clear()
	for n in _nodes:
		if is_instance_valid(n) and not n.is_queued_for_deletion():
			n.free()
	_nodes.clear()


func _make_view() -> Node:
	var v := _FakeView.new()
	_nodes.append(v)
	return v


## 独立池：idle_parent 用测试自己的空节点，不碰 PoolService 的常驻容器
func _new_pool() -> Pool:
	var idle := Node.new()
	_nodes.append(idle)
	var pool := Pool.new()
	pool.idle_parent = idle
	pool.factory = _make_view
	return pool


func test_get_creates_then_reuses() -> void:
	var pool := _new_pool()
	var a := pool.pool_get()
	var b := pool.pool_get()
	assert_true(a != null and b != null, "空池应能现场创建")
	assert_true(a != b, "两次取出应是两个不同实例")
	assert_eq(pool.created_count, 2, "两次现场创建")

	pool.pool_return(a)
	assert_eq(pool.idle_count(), 1, "归还后应有 1 个空闲")
	assert_eq(pool.in_use_count(), 1, "另一个仍在借出")

	var c := pool.pool_get()
	assert_true(c == a, "应复用归还的那个实例")
	assert_eq(pool.created_count, 2, "复用不应再计入创建")
	assert_eq(pool.reused_count, 1, "复用次数应 +1")


func test_return_is_idempotent() -> void:
	var pool := _new_pool()
	var a := pool.pool_get()
	pool.pool_return(a)
	pool.pool_return(a)
	assert_eq(pool.idle_count(), 1, "重复归还不能多出一份空闲")
	assert_eq(pool.in_use_count(), 0, "重复归还后借出计数为 0")


func test_foreign_instance_is_ignored() -> void:
	var pool := _new_pool()
	var stranger := _make_view() as Node
	pool.pool_return(stranger)
	assert_false(pool.is_in_use(stranger), "非本池取出的实例不算借出")
	assert_eq(pool.idle_count(), 0, "非本池实例不入池")
	assert_true(is_instance_valid(stranger), "非本池实例池不负责销毁")


func test_hooks_only_use_return_name() -> void:
	var pool := _new_pool()
	var v := pool.pool_get() as _FakeView
	pool.pool_return(v)
	assert_eq(v.hooks, [&"get", &"return"], "只应调用 on_pool_get / on_pool_return（on_pool_push 已废弃）")


func test_hooks_can_be_disabled() -> void:
	var pool := _new_pool()
	pool.lifecycle_hooks = false
	var v := pool.pool_get() as _FakeView
	pool.pool_return(v)
	assert_true(v.hooks.is_empty(), "关掉 lifecycle_hooks 后不应回调")


func test_max_idle_discards_overflow() -> void:
	var pool := _new_pool()
	pool.max_idle = 1
	var a := pool.pool_get()
	var b := pool.pool_get()
	pool.pool_return(a)
	pool.pool_return(b)
	assert_eq(pool.idle_count(), 1, "超出空闲上限的归还应销毁而不是入池")


func test_prewarm_respects_max_idle() -> void:
	var pool := _new_pool()
	pool.prewarm(3)
	assert_eq(pool.idle_count(), 3, "预热 3 个")
	assert_eq(pool.created_count, 3, "预热计入创建数")

	var capped := _new_pool()
	capped.max_idle = 2
	capped.prewarm(5)
	assert_eq(capped.idle_count(), 2, "预热同样受空闲上限约束")


func test_freed_in_use_is_pruned() -> void:
	var pool := _new_pool()
	var dead := pool.pool_get()
	dead.free()
	assert_eq(pool.in_use_count(), 1, "外部销毁的实例此刻仍记在借出表里（尚未清理）")

	## 借还各算一次计数，80 次足够跨过摊还清理阈值
	for i in 40:
		var v := pool.pool_get()
		pool.pool_return(v)
	assert_eq(pool.in_use_count(), 0, "摊还清理应剪掉已失效的借出条目")


func test_service_isolates_keys() -> void:
	PoolService.ensure(KEY_A, _make_view)
	PoolService.ensure(KEY_B, _make_view)

	var a := PoolService.pool_get(KEY_A)
	assert_true(a != null, "KEY_A 应能取到实例")
	assert_eq(PoolService.find(KEY_B).in_use_count(), 0, "KEY_B 不应被 KEY_A 的借出影响")

	PoolService.pool_return(KEY_A, a)
	assert_eq(PoolService.find(KEY_A).idle_count(), 1, "归还进自己的池")
	assert_eq(PoolService.find(KEY_B).idle_count(), 0, "不能串到别的池")

	assert_true(PoolService.pool_get("test_pool_missing") == null, "没有池时取用返回 null")


func test_service_hands_out_after_key_cleanup() -> void:
	## 场景切换常调 trim()：空闲被清掉、池与 key 保留，再借仍能现场造
	var pool := PoolService.ensure(KEY_A, _make_view)
	var a := pool.pool_get()
	pool.pool_return(a)
	PoolService.trim()
	assert_eq(pool.idle_count(), 0, "trim 应清空空闲实例")
	assert_true(PoolService.find(KEY_A) == pool, "trim 不移除注册")
	assert_true(pool.pool_get() != null, "trim 后仍能借到实例")


func test_idle_instances_stay_in_tree() -> void:
	## 池首次创建常常发生在场景 _ready 期间，那时 root 仍在装配子节点：
	## 容器必须延迟挂载成功，否则所有空闲实例都留在树外（既不渲染也不随场景释放）
	var pool := PoolService.ensure(KEY_A, _make_view)
	var a := pool.pool_get()
	pool.pool_return(a)
	await Engine.get_main_loop().process_frame

	assert_true(a.get_parent() != null, "归还的实例应有父节点")
	assert_true(a.get_parent().is_inside_tree(), "空闲实例应随 PoolIdle 容器入树")
	assert_true(Engine.get_main_loop().root.get_node_or_null("PoolIdle") != null, "PoolIdle 应挂在树根下")


func test_service_accepts_path_like_key() -> void:
	## 旧实现把 key 当 NodePath 解析，含 / 的 key 会建错容器
	var pool := PoolService.ensure(KEY_BAD, _make_view)
	var a := pool.pool_get()
	pool.pool_return(a)
	assert_eq(pool.idle_count(), 1, "含 / 与 : 的 key 也要能建出容器并归还成功")


func test_return_without_pool_destroys() -> void:
	var orphan := _make_view() as Node
	PoolService.pool_return("test_pool_missing", orphan)
	assert_true(orphan.is_queued_for_deletion(), "没有对应池时应直接销毁")
