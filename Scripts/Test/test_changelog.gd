class_name test_changelog
extends TestCase

## 更新日志（ChangelogTool）回归测试。
## 依赖示例内容：res://Assets/Def/Changelog/ChangelogExample.tres（v0.5.0，3 个条目：2 玩家可见 + 1 开发向）


func _setup(version := "0.5.0") -> void:
	ProjectSettings.set_setting(ChangelogTool.SETTING_VERSION, version)
	ChangelogTool.reset_seen_version()


func test_defs_load() -> void:
	_setup()
	var defs := ChangelogTool._load_defs()
	assert_eq(defs.size(), 1, "应扫描到示例 ChangelogDef")
	if defs.is_empty():
		return
	assert_eq(defs[0].entries.size(), 3, "示例应有 3 个条目")
	assert_eq(ChangelogTool.get_max_def_version(), "0.5.0", "最高版本应为 0.5.0")


func test_first_run_no_update() -> void:
	_setup()
	# 首次运行：无已见版本记录，不弹窗
	assert_eq(ChangelogTool.get_seen_version(), "", "首次运行已见版本应为空")
	assert_false(ChangelogTool.has_update(), "首次运行不应弹更新日志")


func test_pending_filter() -> void:
	_setup()
	ChangelogTool.mark_seen("0.4.0")  # 模拟上次已见 0.4.0
	assert_true(ChangelogTool.has_update(), "0.5.0 > 0.4.0 应提示更新")
	var entries := ChangelogTool.get_pending_entries()
	assert_eq(entries.size(), 2, "只应返回玩家可见的 2 条（开发向条目被过滤）")


func test_pending_excludes_newer_than_current() -> void:
	_setup("0.4.0")  # 当前版本低于示例条目的 0.5.0
	ChangelogTool.mark_seen("0.3.0")
	assert_false(ChangelogTool.has_update(), "没有位于已见与当前之间的条目，不应提示")
	assert_true(ChangelogTool.get_pending_entries().is_empty(), "高于当前版本的条目不应展示")


func test_mark_seen() -> void:
	_setup()
	ChangelogTool.mark_seen("0.4.0")
	assert_true(ChangelogTool.has_update(), "记录旧版本后应提示")
	ChangelogTool.mark_seen()  # 记录当前版本
	assert_eq(ChangelogTool.get_seen_version(), "0.5.0", "应记录当前版本")
	assert_false(ChangelogTool.has_update(), "已看到最新版本后不应提示")


func test_downgrade_no_update() -> void:
	_setup("0.4.0")  # 当前版本回退到旧版
	ChangelogTool.mark_seen("0.5.0")
	assert_false(ChangelogTool.has_update(), "版本回退不应提示更新")


func test_seen_version_roundtrip() -> void:
	_setup()
	ChangelogTool.mark_seen("0.4.0")
	var save_val := ChangelogTool.get_seen_version()  # 模拟并入游戏存档
	ChangelogTool.reset_seen_version()
	assert_eq(ChangelogTool.get_seen_version(), "", "重置后已见版本应为空")
	ChangelogTool.load_seen_version(save_val)  # 模拟读档恢复
	assert_eq(ChangelogTool.get_seen_version(), "0.4.0", "读档应恢复已见版本")


func test_load_seen_version_default() -> void:
	_setup()
	ChangelogTool.load_seen_version(null)  # 旧存档无该字段
	assert_eq(ChangelogTool.get_seen_version(), "", "缺字段应视为空，不弹窗")
	assert_false(ChangelogTool.has_update(), "首次（空已见）不应弹窗")