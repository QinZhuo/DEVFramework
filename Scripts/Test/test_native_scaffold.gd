extends TestCase

## 零配置骨架的契约: 只要 gdextension/src 下有 .cpp, 构建脚本就能补齐
## CMakeLists / generated/sources.cmake / generated/register_types.cpp / *.gdextension。
##
## 单独测渲染函数 + 临时目录落地(不碰真实工程), 因为这层一旦出错会写坏别人的仓库。

const SCAFFOLD := preload("res://addons/DEVFramework/Core/Editor/Generate/NativeScaffold.gd")
const PROBE := "user://scaffold_probe"


## 源文件清单: 路径要带上 ${CMAKE_CURRENT_SOURCE_DIR}, 否则 include 后是相对构建目录
func test_render_sources_cmake() -> void:
	var text: String = SCAFFOLD.render_sources_cmake(PackedStringArray(["src/a.cpp", "src/sub/b.cpp"]))
	assert_true(text.contains("${CMAKE_CURRENT_SOURCE_DIR}/src/a.cpp"), "应带源码目录前缀")
	assert_true(text.contains("${CMAKE_CURRENT_SOURCE_DIR}/src/sub/b.cpp"), "子目录也要覆盖")
	assert_true(text.contains("set(DEV_SOURCES"), "变量名必须与生成的 CMakeLists 一致")


## 自动注册: 扫到的类每个一条 GDREGISTER_CLASS, 入口符号 = <target>_library_init
func test_render_register_types() -> void:
	var classes := [
		{"name": "HelloNode", "header": "src/hello.h"},
		{"name": "OtherNode", "header": "src/hello.h"},   # 同一个头只 include 一次
	]
	var text: String = SCAFFOLD.render_register_types(classes, "probe", "4.7")
	assert_eq(text.count("#include \"src/hello.h\""), 1, "同一个头文件只 include 一次")
	assert_true(text.contains("GDREGISTER_CLASS(HelloNode);"), "应注册 HelloNode")
	assert_true(text.contains("GDREGISTER_CLASS(OtherNode);"), "应注册 OtherNode")
	assert_true(text.contains("probe_library_init"), "入口符号必须与 .gdextension 的 entry_symbol 对应")
	assert_true(text.contains("MODULE_INITIALIZATION_LEVEL_SCENE"), "初始化级别固定 SCENE")


## 生成的 CMakeLists: 引用 generated/sources.cmake、产物直出到框架 Native 目录
func test_render_cmake() -> void:
	var text: String = SCAFFOLD.render_cmake("probe", "4.7")
	assert_true(text.contains("add_library(probe SHARED"), "应建共享库")
	assert_true(text.contains("generated/sources.cmake"), "应包含生成的源文件清单")
	assert_true(text.contains("generated/register_types.cpp"), "应包含生成的注册文件")
	assert_true(text.contains("addons/DEVFramework/Native"), "产物要直出到 Native 目录")
	assert_true(text.contains("GODOTCPP_API_VERSION"), "API 版本要可被 -D 覆盖")

	# 工程自带 register_types.cpp: 不能再挂生成的入口(否则同一符号定义两次)
	var own: String = SCAFFOLD.render_cmake("probe", "4.7", false)
	assert_false(own.contains("generated/register_types.cpp"), "自带入口时不应引用生成的注册文件")
	assert_true(own.contains("add_library(probe SHARED ${DEV_SOURCES})"), "自带入口时只用源清单")


## 生成的声明: entry_symbol 与产物键都要齐(否则引擎加载不到)
func test_render_gdextension() -> void:
	var text: String = SCAFFOLD.render_gdextension("probe")
	assert_true(text.contains("entry_symbol = \"probe_library_init\""), "入口符号")
	assert_true(text.contains("windows.release.x86_64"), "windows 键")
	assert_true(text.contains("macos.release"), "macos 键")
	assert_true(text.contains("linux.release.x86_64"), "linux 键")


## 扫描: 从源码里认出 GDCLASS 并找到它所在的头文件
func test_scan_gdclasses() -> void:
	_clean_probe()
	var abs := ProjectSettings.globalize_path(PROBE)
	DirAccess.make_dir_recursive_absolute(abs.path_join("src"))
	_write(abs.path_join("src/hello.h"), "class HelloNode : public Node {\n\tGDCLASS(HelloNode, Node)\n};\n")
	_write(abs.path_join("src/hello.cpp"), "#include \"hello.h\"\n")
	var sources: PackedStringArray = SCAFFOLD.scan_sources(abs)
	assert_eq(sources, PackedStringArray(["src/hello.cpp"]), "只收 .cpp/.cc")
	var classes: Array = SCAFFOLD.scan_gdclasses(abs, PackedStringArray(["src/hello.h"]))
	assert_eq(classes.size(), 1, "应认出 1 个类")
	assert_eq(String(classes[0]["name"]), "HelloNode", "类名")
	assert_eq(String(classes[0]["header"]), "src/hello.h", "头文件路径(供 include)")
	_clean_probe()


## 落地: 缺什么补什么; 第二次运行必须什么都不改(幂等)
func test_ensure_is_idempotent() -> void:
	_clean_probe()
	var abs := ProjectSettings.globalize_path(PROBE)
	DirAccess.make_dir_recursive_absolute(abs.path_join("src"))
	_write(abs.path_join("src/hello.h"), "class HelloNode : public Node {\n\tGDCLASS(HelloNode, Node)\n};\n")
	_write(abs.path_join("src/hello.cpp"), "#include \"hello.h\"\n")

	var r1: Dictionary = SCAFFOLD.ensure(abs, "probe", "4.7", false)
	var created: Array = r1.get("created", [])
	assert_true(created.has("CMakeLists.txt"), "缺 CMakeLists 应生成")
	assert_true(created.has("generated/register_types.cpp"), "应生成自动注册")
	assert_eq(int(r1.get("classes", 0)), 1, "应认出 1 个类")
	assert_true(FileAccess.file_exists(abs.path_join("CMakeLists.txt")), "文件要落盘")
	assert_true(FileAccess.get_file_as_string(abs.path_join("generated/register_types.cpp")).contains("GDREGISTER_CLASS(HelloNode);"),
			"生成的注册文件应包含扫描到的类")
	var rescanned: PackedStringArray = SCAFFOLD.scan_sources(abs)
	for p in rescanned:
		assert_false(String(p).contains("generated/"), "generated/ 不能被扫回源清单(否则注册入口被编译两次)")

	var r2: Dictionary = SCAFFOLD.ensure(abs, "probe", "4.7", false)
	assert_true((r2.get("created", []) as Array).is_empty(), "第二次运行不应再写任何文件(幂等)")

	# 手写 CMakeLists(去掉生成标记) → 工具不再接管, 也不产生 generated/*
	_write(abs.path_join("CMakeLists.txt"), "# my own build\nadd_library(probe SHARED ${DEV_SOURCES})\n")
	var r3: Dictionary = SCAFFOLD.ensure(abs, "probe", "4.7", false)
	assert_false((r3.get("created", []) as Array).has("CMakeLists.txt"), "手写文件不能被覆盖")
	assert_eq(FileAccess.get_file_as_string(abs.path_join("CMakeLists.txt")), "# my own build\nadd_library(probe SHARED ${DEV_SOURCES})\n", "内容必须原样保留")
	_clean_probe()


## 多插件: 一个 CMakeLists 里每插件一个 target, godot-cpp 只引入一次。
func test_render_cmake_multi() -> void:
	var plugins := [
		{"target": "alpha", "src_res": "/addons/A/Native/src", "native_res": "/addons/A/Native"},
		{"target": "beta", "src_res": "/addons/B/Native/src", "native_res": "/addons/B/Native"},
	]
	var text: String = SCAFFOLD.render_cmake_multi(plugins, "4.7")
	assert_eq(text.count("add_subdirectory"), 1, "godot-cpp 只能引入一次(共享构建树)")
	assert_true(text.contains("add_library(alpha SHARED"), "alpha 目标")
	assert_true(text.contains("add_library(beta SHARED"), "beta 目标")
	assert_true(text.contains("/addons/A/Native") and text.contains("/addons/B/Native"), "各插件产物目录")
	# 多扩展同进程: 必须隐藏非入口符号, 否则 godot-cpp 的 inline weak 符号互相抢占
	assert_true(text.contains("CMAKE_CXX_VISIBILITY_PRESET hidden"), "必须隐藏符号可见性")
	assert_true(text.contains("add_subdirectory"), "引入 godot-cpp")


## 跨插件同名 GDCLASS: 必须能提前判出(引擎报错很难定位)。
func test_find_class_conflicts() -> void:
	var plugins := [
		{"target": "alpha", "classes": [{"name": "SharedNode"}, {"name": "OnlyA"}]},
		{"target": "beta", "classes": [{"name": "SharedNode"}]},
	]
	var cs: Array = SCAFFOLD.find_class_conflicts(plugins)
	assert_eq(cs.size(), 1, "只应报出 1 个冲突类")
	assert_eq(String(cs[0]["name"]), "SharedNode", "冲突类名")
	assert_eq((cs[0]["targets"] as Array).size(), 2, "两个插件都声明了它")


## 多插件落地: 每个插件的源码留在自己目录, 构建区/生成物在项目根。
func test_ensure_project_multi_plugin() -> void:
	_clean_probe()
	var abs := ProjectSettings.globalize_path(PROBE)
	for side in [["A", "ANode"], ["B", "BNode"]]:
		var src := abs.path_join("addons").path_join(String(side[0])).path_join("Native").path_join("src")
		DirAccess.make_dir_recursive_absolute(src)
		_write(src.path_join("node.h"), "class %s : public Node {\n\tGDCLASS(%s, Node)\n};\n" % [side[1], side[1]])
		_write(src.path_join("node.cpp"), "#include \"node.h\"\n")

	var r: Dictionary = SCAFFOLD.ensure_project(abs, "4.7", false)
	var plugins: Array = r.get("plugins", [])
	assert_eq(plugins.size(), 2, "应发现 2 个原生插件")
	assert_eq((r.get("conflicts", []) as Array).size(), 0, "无同名类")

	var cmake := abs.path_join("gdextension/CMakeLists.txt")
	assert_true(FileAccess.file_exists(cmake), "项目级构建区应生成 CMakeLists")
	var text := FileAccess.get_file_as_string(cmake)
	assert_eq(text.count("add_subdirectory"), 1, "godot-cpp 只编一次")
	assert_eq(text.count("add_library("), 2, "两个插件两个 target")
	assert_true(FileAccess.file_exists(abs.path_join("gdextension/generated/A_sources.cmake")), "A 的源清单")
	assert_true(FileAccess.file_exists(abs.path_join("gdextension/generated/B_register_types.cpp")), "B 的注册表")
	assert_true(FileAccess.file_exists(abs.path_join("addons/A/Native/A.gdextension")), "A 的声明")
	# 插件源码不得被搬走
	assert_true(FileAccess.file_exists(abs.path_join("addons/A/Native/src/node.cpp")), "源码留在插件目录")

	# 再来一个重名类 → 冲突检测必须报出
	_write(abs.path_join("addons/B/Native/src/dup.h"), "class ANode : public Node {\n\tGDCLASS(ANode, Node)\n};\n")
	var r2: Dictionary = SCAFFOLD.ensure_project(abs, "4.7", false)
	assert_eq((r2.get("conflicts", []) as Array).size(), 1, "ANode 在两个插件里都有 → 冲突")
	_clean_probe()


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()


func _clean_probe() -> void:
	var abs := ProjectSettings.globalize_path(PROBE)
	_rm_tree(abs)


func _rm_tree(dir_path: String) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if d.current_is_dir():
			_rm_tree(full)
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
		name = d.get_next()
	d.list_dir_end()
