extends TestCase

## 框架契约回归：脚本代次/新鲜度 / Entity3D.ecs_world 命名空间。
## 这些是"骨架层"的约定，不属于某个玩法模块。
## 用 preload 而不是全局类名：新增全局类在 headless/编辑器首次运行时可能尚未进入全局类表。
const EpochTool := preload("res://addons/DEVFramework/Core/Tool/ScriptEpochTool.gd")
const FreshnessTool := preload("res://addons/DEVFramework/Core/Tool/ScriptFreshnessTool.gd")

func test_entity3d_ecs_world_property() -> void:
	var entity := Entity3D.new()
	# 不依赖 ECS 原生库：先验证"命名空间"（旧 world 必须让出来）。
	assert_true("ecs_world" in entity, "Entity3D 应暴露 ecs_world")
	assert_false("world" in entity, "Entity3D 不应再占用 world 字段名")
	entity.free()

func test_entity2d_ecs_world_property() -> void:
	var entity := Entity2D.new()
	assert_true("ecs_world" in entity, "Entity2D 应暴露 ecs_world")
	assert_false("world" in entity, "Entity2D 不应再占用 world 字段名")
	entity.free()

func test_script_epoch_registry() -> void:
	var state := {"calls": 0}
	var clearer := func() -> void: state["calls"] = int(state["calls"]) + 1
	assert_true(EpochTool.register_cache(&"test_contract", clearer))
	EpochTool.bump("test_contract")   # 让代次变化；begin_run 只在变化时清
	var before := EpochTool.current()
	var after := EpochTool.begin_run("test_contract")
	assert_eq(after, before, "begin_run 本身不递增代次（bump 才递增）")
	assert_true(int(state["calls"]) >= 1, "代次变化时 begin_run 应调用注册的清缓存回调")
	var calls_after := int(state["calls"])
	EpochTool.begin_run("same_epoch")
	assert_eq(int(state["calls"]), calls_after, "代次没变时不应重复清缓存")
	EpochTool.unregister_cache(&"test_contract")
	assert_false((EpochTool.status()["caches"] as Array).has(&"test_contract"))

func test_script_epoch_bump_monotonic() -> void:
	var a := EpochTool.bump("probe_a")
	var b := EpochTool.bump("probe_b")
	assert_true(b > a, "bump 应单调递增")

func test_self_script_is_in_sync() -> void:
	var status := FreshnessTool.status("res://Scripts/Test/test_framework_contracts.gd")
	assert_eq(str(status.get("state", "")), "in_sync", "刚加载的测试脚本应与磁盘一致")
func test_job_start_returns_before_work_runs() -> void:
	# MCP 下 TestRunner 本身就跑在一个 job 里，嵌套 start 会返回外层 job，测不了；
	# headless 直接跑 TestRunner 时 JobTool 是空闲的，正好验证"先给 job_id、下一空闲才执行"。
	if bool(JobTool.status().get("running", false)):
		return
	JobTool.clear()
	var state := {"done": false}
	var snap := JobTool.start("test_job_defer", func() -> Dictionary:
		state["done"] = true
		return {"ok": true})
	assert_true(bool(snap.get("running", false)), "JobTool.start 应立即返回 running")
	var result: Dictionary = await JobTool.wait(str(snap.get("job_id", "")), 5000)
	assert_eq(str(result.get("status", "")), "done", "job 应在下一空闲执行完")
	assert_true(bool(state["done"]), "work 应已执行")
func test_freshness_policy_override() -> void:
	var old := TestRunner.freshness_mode()
	TestRunner.set_freshness_mode("warn")
	assert_eq(TestRunner.freshness_mode(), "warn")
	TestRunner.set_freshness_mode("off")
	assert_eq(TestRunner.freshness_mode(), "off")
	TestRunner.set_freshness_mode(old)
