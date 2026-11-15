class_name test_framework_compile
extends TestCase

## 编译健康检查 — 不维护"脚本清单"，直接扫全量 + 校验源码里的路径引用。
##
## 为什么需要它: 改名漏改 / 引用已删成员 / 与内置成员撞名时, 编辑器会刷
## `Compile Error: Failed to compile depended scripts`, 而且会把 TestRunner、MCP 等
## 无关模块一起拖垮; 根因往往只是某个脚本的一行。功能测试抓不到"模块根本没加载"。
##
## 两个用例:
##   1) 全量扫描: 目录下每个 .gd 都必须能 load 且编译成功(方法表非空)
##   2) 路径存在性: 源码里引用的 res://addons/DEVFramework/… 必须真实存在
##
## 曾经还有"扫日志找编译错误"的第三个用例, 已删除: 日志是**追加**的, 启动横幅只出现在
## 文件最开头, 没法从文件里切出"本次会话", 扫全文只会把历史错误一直算在头上。
## 查本次编译错误请用 MCP `get_logs(process=…, kind=error)`。

const ROOT_DIRS: Array[String] = ["res://addons/DEVFramework", "res://Scripts"]


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
	for path in _collect_scripts():
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


## 原生库新鲜度: 改了 gdextension/src 却忘了重编时, 所有原生相关测试都会"跑旧库还全绿"。
## 这是唯一能自动发现该问题的检查点, 所以归到编译健康检查里。
func test_native_library_is_fresh() -> void:
	var st: Dictionary = GDExtensionRebuild.native_status()
	if not bool(st.get("has_native", false)):
		return   # 纯 GDScript 项目 / 未部署原生产物: 不适用
	assert_false(bool(st.get("stale", false)),
			"原生源码比已编译库新(库=%s): 先 build_native(或菜单 GDExtensionRebuild) 再跑测试, 否则测的是旧代码" % str(st.get("lib", "")))


static func _collect_scripts() -> PackedStringArray:
	var result := PackedStringArray()
	for root: String in ROOT_DIRS:
		result.append_array(FileTool.list_files(root, PackedStringArray([".gd"])))
	return result
