class_name test_mcp_instance_hub
extends TestCase

## MCP 多实例中枢(MCPInstanceHub)回归。
##
## 只测**纯逻辑**: 身份计算、注册表增删、标识解析、路由绑定、死成员剔除。
## 不测端口绑定、心跳与 HTTP 转发 —— 那几项依赖真实进程与真实端口, 在 headless 测试进程里
## 绑端口会与正在运行的编辑器抢端口, 而且"两个进程"本身也无法在单进程用例里构造。
## 那部分的验证方式是真实的双编辑器联调(见 addons/DEVFramework/Readme.md §7.3)。
##
## 依赖: 用 MCPDevServer 的 _mod 取脚本会拿到**服务器实例的编译缓存**; 这里直接按路径 load,
## 目的是测"磁盘上的那份", 与服务器是否在跑无关。

const HUB_PATH := "res://addons/DEVFramework/MCP/MCPInstanceHub.gd"

## 默认目标会落盘：用例必须把它重定向到临时路径，否则跑一次测试就改掉真实会话的目标。
const TEST_TARGET := "user://test_hub_target.json"

var _hub: Variant


func cleanup() -> void:
	_hub = null
	var gd: Variant = load(HUB_PATH)
	if gd != null:
		gd.target_path_override = ""
	if FileAccess.file_exists(TEST_TARGET):
		DirAccess.remove_absolute(TEST_TARGET)


func _new_hub(uid := "Self@self#1", id := "Self@self", name := "Self", path := "D:/self") -> Variant:
	var gd: Variant = load(HUB_PATH)
	if gd == null:
		return null
	gd.target_path_override = TEST_TARGET
	_hub = gd.new()
	_hub.set_self(uid, id, name, path)
	_hub.set_self_port(8001)
	return _hub


func test_instance_id_is_stable_and_path_normalized() -> void:
	# 同一路径的不同写法必须算出同一个 id: 盘符大小写、反斜杠、尾分隔符都是最常见的三种差异。
	var a := HUB_PATH # 仅用于确保常量被用到, 避免"未使用"告警
	assert_ne(a, "", "常量应有值")
	var gd: Variant = load(HUB_PATH)
	assert_ne(gd, null, "中枢脚本应能加载")
	var id1: String = gd.make_instance_id("MyGame", "D:/Work/MyGame")
	var id2: String = gd.make_instance_id("MyGame", "d:\\work\\mygame\\")
	var id3: String = gd.make_instance_id("MyGame", "D:/Work/MyGame/")
	assert_eq(id1, id2, "路径写法差异(大小写/反斜杠)不应改变实例 id")
	assert_eq(id1, id3, "尾分隔符不应改变实例 id")
	assert_true(id1.begins_with("MyGame@"), "实例 id 应以项目名开头")
	assert_eq(id1.length(), "MyGame@".length() + 8, "哈希部分应为 8 位")
	# 不同项目必须算出不同 id, 否则"默认目标"会串项目
	assert_ne(id1, gd.make_instance_id("MyGame", "D:/Work/MyGame2"), "不同项目路径必须得到不同 id")


func test_project_name_is_sanitized() -> void:
	var gd: Variant = load(HUB_PATH)
	assert_eq(gd.safe_name("My Game"), "My_Game", "空格必须替换成下划线")
	assert_eq(gd.safe_name("a/b\\c:d"), "a_b_c_d", "路径分隔符与冒号必须替换")
	assert_eq(gd.safe_name(""), "project", "空项目名要有兜底")
	# 过长项目名必须被截断, 否则 id 会长到没法在清单里读
	assert_true(gd.safe_name("x".repeat(200)).length() <= 40, "项目名片段应截断到 40 字符内")


func test_register_and_prune() -> void:
	var h: Variant = _new_hub()
	assert_ne(h, null, "应能创建中枢实例")
	assert_eq(h.snapshot().size(), 1, "刚建好时应只有本实例")
	h.upsert({"uid": "B@b#2", "instance_id": "B@b", "name": "B", "project_path": "D:/b", "port": 9001})
	assert_eq(h.snapshot().size(), 2, "登记一个成员后应有 2 个实例")
	# 幂等: 重复登记同一 uid 不应产生第二条
	h.upsert({"uid": "B@b#2", "instance_id": "B@b", "name": "B", "project_path": "D:/b", "port": 9002})
	assert_eq(h.snapshot().size(), 2, "重复登记同一个 uid 必须幂等")
	assert_eq(h.resolve("9002").get("port", 0), 9002, "重复登记应更新端口")
	# 端口非法的登记必须被拒(否则会被路由到一个必然连不上的地址)
	h.upsert({"uid": "Bad@x#3", "instance_id": "Bad@x", "port": 0})
	assert_true(h.resolve("Bad@x").is_empty(), "端口为 0 的登记应被拒绝")
	# 自己不能被成员覆盖
	var own_port: int = h.own_port
	h.upsert({"uid": h.own_uid, "instance_id": h.own_instance_id, "port": 12345})
	assert_eq(h.own_port, own_port, "成员不得覆盖中枢自身的端口")
	# 心跳超时的成员必须被剔除, 否则调用方会去选一个已经关掉的实例
	h.members["B@b#2"]["last_seen"] = Time.get_ticks_msec() - 60000
	assert_eq(h.snapshot().size(), 1, "心跳超时的成员应被剔除")
	assert_true(h.resolve("B@b").is_empty(), "被剔除的成员不应还能被解析")


func test_resolve_by_each_selector() -> void:
	var h: Variant = _new_hub()
	h.upsert({"uid": "PCG@a1b2c3d4#42", "instance_id": "PCG@a1b2c3d4", "name": "PCG", "project_path": "D:/pcg", "port": 51234})
	# 四档选择器: uid / instance_id / 端口 / 唯一前缀
	assert_eq(h.resolve("PCG@a1b2c3d4#42").get("port", 0), 51234, "uid 精确匹配")
	assert_eq(h.resolve("PCG@a1b2c3d4").get("port", 0), 51234, "instance_id 精确匹配")
	assert_eq(h.resolve("51234").get("port", 0), 51234, "端口号匹配")
	assert_eq(h.resolve("a1b2").get("port", 0), 51234, "hash 前缀匹配")
	assert_eq(h.resolve("PCG").get("port", 0), 51234, "项目名前缀匹配")
	# 不存在 / 不唯一前缀 -> 空(绝不猜)
	assert_true(h.resolve("nope").is_empty(), "不存在的标识应返回空")
	assert_true(h.resolve("").is_empty(), "空标识应返回空")
	assert_true(h.resolve("P").size() > 0, "唯一前缀 P 应能命中(只有 PCG 以 P 开头)")


func test_duplicate_instance_id_is_ambiguous() -> void:
	# 同一项目被打开两次: instance_id 相同, 此时**不能**替调用方挑一个。
	# 挑错的后果是把 A 窗口的改动写进 B 窗口, 而这正是多开时最贵的错误。
	var h: Variant = _new_hub()
	h.upsert({"uid": "B@b#2", "instance_id": "B@b", "name": "B", "project_path": "D:/b", "port": 9001})
	h.upsert({"uid": "B@b#3", "instance_id": "B@b", "name": "B", "project_path": "D:/b", "port": 9003})
	assert_true(h.resolve("B@b").is_empty(), "同项目多开时 instance_id 有歧义, 必须返回空")
	assert_true(h.count_matches("B@b") >= 2, "count_matches 应报出有多个匹配(供调用方区分'不存在'与'有歧义')")
	# 但唯一键仍然可用 —— 这是调用方被要求改用的那条路
	assert_eq(h.resolve("B@b#3").get("port", 0), 9003, "同项目多开时 uid 仍可精确定位")
	assert_eq(h.resolve("9001").get("port", 0), 9001, "同项目多开时端口仍可精确定位")


func test_default_target_uses_uid_not_instance_id() -> void:
	# 默认目标若按 instance_id 记, "选中 A 窗口"会在同项目的 B 窗口也生效, 且两边 id 完全相同,
	# 从错误信息里根本看不出问题。故绑定键必须是 uid。
	var h: Variant = _new_hub()
	h.upsert({"uid": "B@b#2", "instance_id": "B@b", "name": "B", "project_path": "D:/b", "port": 9001})
	h.set_active({"uid": "B@b#2", "instance_id": "B@b", "project_path": "D:/b"})
	assert_eq(h.active_instance, "B@b#2", "默认目标应记录 uid")
	assert_eq(h.active_instance_id, "B@b", "同时要记项目级 id，供重启后接回")
	assert_true(h.active_is_remote(), "指向别的实例时应判定为远端")
	h.set_active({"uid": h.own_uid, "instance_id": h.own_instance_id, "project_path": "D:/self"})
	assert_false(h.active_is_remote(), "指向自己时不应判定为远端")
	h.set_active({})
	assert_false(h.active_is_remote(), "未设置默认目标时不应判定为远端")
	assert_false(h.has_active(), "清空后不应再认为设过默认目标")


func test_snapshot_shape() -> void:
	# 快照是 AI 唯一能看到的实例视图, 少一个字段就得让它在别处再查一次。
	var h: Variant = _new_hub()
	h.set_hub_mode(true)
	var snap: Array = h.snapshot()
	assert_eq(snap.size(), 1, "初始应有本实例一条")
	var item: Dictionary = snap[0]
	for key in ["instance_id", "uid", "name", "project_path", "port", "is_self", "is_hub", "age_ms"]:
		assert_true(item.has(key), "快照条目应含字段 %s" % key)
	assert_true(bool(item.get("is_self", false)), "本实例应标记 is_self")
	assert_true(bool(item.get("is_hub", false)), "持有中枢端口的实例应标记 is_hub")
	# uid 必须出现在对外快照里: 同项目多开时它是**唯一**能精确指定某一个进程的选择器,
	# 而 use_instance 的歧义报错直接叫调用方"改用 uid" —— 清单里没有它就等于让人去猜。
	assert_eq(str(item.get("uid", "")), h.own_uid, "快照应带 uid(唯一选择器)")
	assert_false(item.has("last_seen"), "对外快照不应泄漏内部时间戳(调用方看 age_ms 即可)")
