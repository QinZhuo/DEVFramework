extends TestCase

## 多实例路由的契约（不依赖真实网络与编辑器进程）：
##   · 目标离线 **必须报错**，不能回落"就地执行"（那不是降级，是静默改错项目）
##   · 目标在线 → 给出端口转发
##   · uid 失效（编辑器重启换了进程号）→ 按 instance_id 接回同一个项目

const HUB := preload("res://addons/DEVFramework/MCP/MCPInstanceHub.gd")
const ROUTER := preload("res://addons/DEVFramework/MCP/MCPRouter.gd")

## 路由层只读 server 的这三个成员；用假 server 就能在无网络下测完整决策链。
class FakeServer:
	var _hub = null
	var _hub_port := 9988

	func _game_call_timeout_ms() -> int:
		return 1000

## 默认目标文件是**机器级共享状态**：用例会写它。这里把它重定向到临时路径，
## 否则跑一次测试就会改掉开发者真实会话的默认目标（曾实际发生过）。
const TEST_TARGET := "user://devframework_mcp_target.test.json"


func _init() -> void:
	HUB.target_path_override = TEST_TARGET


func cleanup() -> void:
	HUB.target_path_override = ""
	if FileAccess.file_exists(TEST_TARGET):
		DirAccess.remove_absolute(TEST_TARGET)


func _entry(uid: String, iid: String, port: int, is_self := false) -> Dictionary:
	return {"uid": uid, "instance_id": iid, "project_path": "D:/" + iid, "port": port, "is_self": is_self}


func _hub_with(members: Dictionary, active_uid := "", active_iid := "", hub_mode := true) -> Variant:
	# 每条用例都要设一次：runner 在用例之间调 cleanup()，那里会把它还原。
	# 只写在 _init 里是不够的 —— 第一个用例之后就会被 cleanup 清掉，后续用例便写进真实文件。
	HUB.target_path_override = TEST_TARGET
	var h = HUB.new()
	h.hub_mode = hub_mode
	h._target_loaded = true          # 不读磁盘，避免用例受真实目标文件影响
	h.members = members
	h.active_instance = active_uid
	h.active_instance_id = active_iid
	h.active_project_path = "" if active_iid.is_empty() else "D:/" + active_iid
	return h


func _router(hub: Variant) -> Variant:
	var s := FakeServer.new()
	s._hub = hub
	return ROUTER.new(s)


func test_target_offline_errors() -> void:
	var h: Variant = _hub_with({
		"Other@zzz#9": _entry("Other@zzz#9", "Other@zzz", 9988, true),
	}, "Gone@abc#7", "Gone@abc")
	var r: Dictionary = _router(h).resolve_route("list_dir", {})
	assert_true(r.has("error"), "目标不在线时必须报错，不能就地执行")
	assert_false(r.has("port"), "报错时不应给出端口")


func test_live_target_routes_to_its_port() -> void:
	var h: Variant = _hub_with({
		"Self@me#1": _entry("Self@me#1", "Self@me", 9988, true),
		"A@abc#3": _entry("A@abc#3", "A@abc", 5555),
	}, "A@abc#3", "A@abc")
	var r: Dictionary = _router(h).resolve_route("list_dir", {})
	assert_eq(int(r.get("port", 0)), 5555, "在线目标应转发到它的端口")
	assert_eq(str(r.get("target", "")), "A@abc")


func test_self_target_runs_locally() -> void:
	var h: Variant = _hub_with({
		"Self@me#1": _entry("Self@me#1", "Self@me", 9988, true),
	}, "Self@me#1", "Self@me")
	var r: Dictionary = _router(h).resolve_route("list_dir", {})
	assert_eq(int(r.get("port", -1)), 0, "目标就是本实例时应就地执行")


func test_restores_by_instance_id_after_restart() -> void:
	# uid 里的 #进程号 变了，instance_id（项目名@路径hash）不变
	var h: Variant = _hub_with({
		"Self@me#1": _entry("Self@me#1", "Self@me", 9988, true),
		"A@abc#42": _entry("A@abc#42", "A@abc", 6001),
	}, "A@abc#7", "A@abc")
	var r: Dictionary = _router(h).resolve_route("list_dir", {})
	assert_eq(int(r.get("port", 0)), 6001, "应按 instance_id 接回同一个项目")
	assert_eq(str(h.active_instance), "A@abc#42", "接回后应把默认目标改写成新 uid")


## 转发结果没有执行方盖章时，由中枢补一个 —— 否则"这条结果来自哪个项目"无从回答。
## 这条曾经因为把 Array 当 Dictionary 用而静默失效（只有转发路径会走到）。
func test_forwarded_result_gets_target_stamp() -> void:
	var h: Variant = _hub_with({
		"A@abc#3": _entry("A@abc#3", "A@abc", 5555),
	})
	var router: Variant = _router(h)
	var resp := {"result": {"content": [{"type": "text", "text": "ok"}]}}
	router._stamp_forwarded(resp, {"target": "A@abc", "uid": "A@abc#3"})

	var meta: Dictionary = resp["result"].get("_meta", {})
	var target: Dictionary = meta.get("target", {})
	assert_eq(str(target.get("instance_id", "")), "A@abc", "转发结果应带上目标实例")
	assert_eq(str(target.get("project_path", "")), "D:/A@abc", "项目路径应从中枢注册表补全")
	assert_true(str(resp["result"]["content"][0]["text"]).contains("[target: A@abc"),
			"正文末尾应附一行可读标记")


func test_member_never_routes() -> void:
	# 成员进程没有注册表：直连它的请求必须就地执行
	var h: Variant = _hub_with({}, "Gone@abc#7", "Gone@abc", false)
	var r: Dictionary = _router(h).resolve_route("list_dir", {})
	assert_eq(int(r.get("port", -1)), 0, "成员进程应就地执行")
