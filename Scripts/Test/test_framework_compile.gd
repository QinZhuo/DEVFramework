class_name test_framework_compile
extends TestCase

## 编译健康检查 — 不维护"脚本清单"，直接扫全量 + 看编辑器日志。
##
## 为什么需要它: 改名漏改 / 引用已删成员 / 与内置成员撞名时, 编辑器会刷
## `Compile Error: Failed to compile depended scripts`, 而且会把 TestRunner、MCP 等
## 无关模块一起拖垮; 根因往往只是某个脚本的一行。功能测试抓不到"模块根本没加载"。
##
## 两个用例:
##   1) 全量扫描: 目录下每个 .gd 都必须能 load 且编译成功(方法表非空)
##   2) 日志检查: 本次编辑器会话新增的日志里不能出现编译类错误

const ROOT_DIRS := ["res://addons/DEVFramework", "res://Scripts"]

## 日志里出现这些即视为"有编译问题"
const LOG_ERROR_PATTERNS := [
	"Parse Error",
	"Compile Error",
	"Failed to load script",
	"Failed to compile depended scripts",
]

## 日志里的"进程启动横幅"; 只看它之后的内容 ⇒ 天然只覆盖本次会话, 不受历史日志干扰
const LOG_SESSION_MARKER := "Godot Engine v"


# ------------------------------------------------------------
# 1. 全量脚本编译
# ------------------------------------------------------------

func test_all_scripts_compile() -> void:
	var scripts := _collect_scripts()
	assert_true(scripts.size() > 50, "脚本扫描数量异常: %d(路径或遍历逻辑有问题)" % scripts.size())

	var broken := []
	for path in scripts:
		var script := load(path) as GDScript
		if script == null:
			broken.append("%s -> load 失败" % path)
			continue
		# 编译失败的脚本 load 仍会返回对象, 但**方法表和属性表都空**(解析失败什么都不剩);
		# 纯数据/纯静态脚本可能没有方法, 但一定有属性 —— 两者一起看才不会误报。
		# 不用 reload(): 已有实例的脚本不允许 reload(ERR_BUSY)
		if script.get_script_method_list().is_empty() and script.get_script_property_list().is_empty():
			broken.append("%s -> 编译失败(无方法也无属性)" % path)

	assert_true(broken.is_empty(),
			"%d 个脚本无法编译:\n%s" % [broken.size(), "\n".join(broken)])


static func _collect_scripts() -> PackedStringArray:
	var result := PackedStringArray()
	for root in ROOT_DIRS:
		_walk(root, result)
	return result


static func _walk(dir_path: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_walk(dir_path.path_join(entry), out)
		elif entry.ends_with(".gd"):
			out.append(dir_path.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()


# ------------------------------------------------------------
# 2. 编辑器日志
# ------------------------------------------------------------

## 日志检查(默认关闭): 只有"先清空日志再启动编辑器"才有意义。
##
## 原因: 日志是**追加**的, "Godot Engine v" 启动横幅只出现在文件最开头,
## 没法从文件里切出"本次会话"; 直接扫全文会把历史错误一直算在头上(误报)。
## 更可靠的是流程: 改完 → 重启编辑器 → 用 MCP `get_logs(kind=error)` 看新错误。
## 想启用本用例: 先删 user://logs/godot.log 再启动编辑器。
const CHECK_LOG_FILE := false


func test_no_compile_errors_in_log() -> void:
	if not CHECK_LOG_FILE:
		return
	var path := _log_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		# 没开文件日志就跳过(不算失败); 想强制检查就打开 debug/file_logging
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return

	var text := file.get_as_text()
	# 只取"最后一次进程启动横幅之后"的内容 ⇒ 就是本次会话, 与历史日志无关
	var start := text.rfind(LOG_SESSION_MARKER)
	if start < 0:
		return
	var session := text.substr(start)
	if session.strip_edges().is_empty():
		return

	var hits := []
	for line in session.split("\n"):
		for pattern in LOG_ERROR_PATTERNS:
			if line.contains(pattern):
				hits.append(line.strip_edges())
				break
	assert_true(hits.is_empty(),
			"本次会话日志里有 %d 条编译错误:\n%s" % [hits.size(), "\n".join(hits)])


static func _log_path() -> String:
	var configured := String(ProjectSettings.get_setting("debug/file_logging/log_path", ""))
	if configured.is_empty():
		configured = "user://logs/godot.log"
	return ProjectSettings.globalize_path(configured) if configured.begins_with("user://") else configured


## 框架内所有 "res://addons/DEVFramework/..." 字符串都必须指向真实文件。
## 目录重组最容易漏的是**非 .gd 后缀** —— 例如 plugin.gd 里的 .tscn / .png,
## 漏掉后编辑器只在启动时报 "Cannot open file", 很难定位到是哪次搬迁造成的。
func test_all_framework_paths_exist() -> void:
	# 必须以**文件扩展名**结尾: 这样"前缀字符串"(如 MCP/)、目录名、以及
	# "dev.gdextension 已加载(…)" 这类提示文本都不会被误判成待校验路径。
	var re := RegEx.new()
	# 长扩展名在前 + 负向前瞻: 否则 "dev.gdextension" 会被截成 "dev.gd"
	re.compile("res://addons/DEVFramework/[^\"\\s]*\\.(gdextension|gdshader|tscn|tres|import|png|svg|gd)(?![a-z])")
	var missing: Array[String] = []
	var checked := 0
	for root in ROOT_DIRS:
		for path in _collect_scripts_for_paths(root):
			if path.get_file() == "test_framework_compile.gd":
				continue  # 自身含注释示例
			var text := FileAccess.get_file_as_string(path)
			if text.is_empty():
				continue
			for line in text.split("\n"):
				if line.strip_edges().begins_with("#"):
					continue  # 注释里的写法示例不校验
				for m in re.search_all(line):
					checked += 1
					var target := m.get_string()
					if not FileAccess.file_exists(target):
						missing.append("%s -> %s" % [path.get_file(), target])
	assert_true(missing.is_empty(), "以下框架路径不存在(搬迁时漏改):\n" + "\n".join(missing))
	assert_true(checked > 0, "未扫描到任何框架路径引用, 检查扫描逻辑")


func _collect_scripts_for_paths(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			if not entry.begins_with("."):
				out.append_array(_collect_scripts_for_paths(full))
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out