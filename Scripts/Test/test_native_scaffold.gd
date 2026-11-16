extends TestCase

## 零配置骨架的契约: 只要 gdextension/src 下有 .cpp, 构建脚本就能补齐
## CMakeLists / generated/sources.cmake / generated/register_types.cpp / *.gdextension。
##
## 单独测渲染函数 + 临时目录落地(不碰真实工程), 因为这层一旦出错会写坏别人的仓库。

const SCAFFOLD := preload("res://addons/DEVFramework/Core/Editor/Generate/NativeScaffold.gd")
const REBUILD := preload("res://addons/DEVFramework/Core/Editor/Generate/GDExtensionRebuild.gd")
const PROBE := "user://scaffold_probe"


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


## 库名规则(与 godot-cpp 官方模板一致): 全平台统一 lib 前缀 + <名>.<平台>.<类型>.<架构>.<ext>。
## 这样 CMake/MinGW 的默认 SHLIBPREFIX 与规范名同前缀, 不需要 PREFIX "" 平台特例;
## 唯一硬约束是 规范名 与 .gdextension 的 [libraries] 一字不差(否则扩展静默加载失败)。
func test_library_name_prefix_per_platform() -> void:
	var rb = REBUILD.new()
	var name: String = rb._canonical_file("probe", "release", "x86_64")
	assert_true(name.begins_with("lib"), "规范名应带 lib 前缀: %s" % name)
	assert_true(name.contains(".release.x86_64"), "应含 类型+架构: %s" % name)
	match rb._os_label():
		"windows":
			assert_true(name.ends_with(".dll"), "Windows 后缀: %s" % name)
		"macos":
			assert_true(name.ends_with(".dylib"), "macOS 后缀: %s" % name)
		"linux":
			assert_true(name.ends_with(".so"), "Linux 后缀: %s" % name)
	# 直出名(CMake 默认)与规范名同前缀, 部署才不需要靠改名兜底
	assert_true(rb._default_out_file("probe").begins_with("lib"), "CMake 直出名也应带 lib")
	# macOS universal 名字与平台无关
	var uni: String = rb._universal_file("probe", "release")
	assert_true(uni.begins_with("lib") and uni.contains(".macos."), "universal 名: %s" % uni)


## CMakeLists 多 target 解析: 每个 add_library 之后的 *_OUTPUT_DIRECTORY 归到它名下。
## 这是多插件部署的地基 —— 解析错就会把产物部署/清理到别的插件目录。
func test_parse_target_outputs_multi() -> void:
	var text := """
project(plugins LANGUAGES CXX)
add_library(alpha SHARED ${ALPHA_SOURCES})
target_link_libraries(alpha PRIVATE godot-cpp)
set_target_properties(alpha PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/A/Native
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/A/Native)

add_library(beta SHARED ${BETA_SOURCES})
set_target_properties(beta PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/B/Native)
"""
	var base := "C:/proj/gdextension"
	var out: Dictionary = REBUILD.parse_target_outputs(text, base)
	assert_eq(out.size(), 2, "应解析出两个 target 的输出目录")
	assert_eq(String(out.get("alpha", "")), "C:/proj/addons/A/Native", "alpha 的目录")
	assert_eq(String(out.get("beta", "")), "C:/proj/addons/B/Native", "beta 的目录(不能串到 alpha)")


## build 的插件选择: "all" 全建; 指定名字只留该 target(大小写不敏感); 名字不存在则空。
func test_filter_targets_by_plugin() -> void:
	var targets := [{"target": "dev"}, {"target": "voxelnative"}]
	assert_eq(REBUILD.filter_targets(targets, "all").size(), 2, "all = 全部")
	assert_eq(REBUILD.filter_targets(targets, "").size(), 2, "空串 = 全部")
	var one: Array = REBUILD.filter_targets(targets, "VOXELNATIVE")
	assert_eq(one.size(), 1, "按名字只留一个(大小写不敏感)")
	assert_eq(String(one[0]["target"]), "voxelnative", "留下的是被点名的那个")
	assert_eq(REBUILD.filter_targets(targets, "nope").size(), 0, "不存在的名字 → 空(调用方据此报错)")


## 单插件源清单: 路径要能相对 gdextension/generated/ 解析(.. 回到项目根再进插件目录)。
func test_render_plugin_sources() -> void:
	var text: String = SCAFFOLD.render_plugin_sources("probe", PackedStringArray(["a.cpp", "sub/b.cpp"]), "/addons/A/Native/src")
	assert_true(text.contains("set(PROBE_SOURCES"), "变量名必须是 <TARGET>_SOURCES")
	assert_true(text.contains("${CMAKE_CURRENT_SOURCE_DIR}/../addons/A/Native/src/a.cpp"), "绝对/相对拼法要一致")
	assert_true(text.contains("sub/b.cpp"), "子目录也要覆盖")


## 自带入口(手写 register_types.cpp)时不能再挂生成的入口文件, 否则符号定义两次。
func test_render_cmake_multi_entry_switch() -> void:
	var p_own := [{"target": "own", "src_res": "/addons/O/Native/src", "native_res": "/addons/O/Native", "with_entry": false}]
	var text: String = SCAFFOLD.render_cmake_multi(p_own, "4.7")
	assert_false(text.contains("own_register_types.cpp"), "自带入口时不得引用生成的入口")
	assert_true(text.contains("add_library(own SHARED ${OWN_SOURCES})"), "只用源清单")
	var p_gen := [{"target": "gen", "src_res": "/addons/G/Native/src", "native_res": "/addons/G/Native"}]
	assert_true(SCAFFOLD.render_cmake_multi(p_gen, "4.7").contains("gen_register_types.cpp"), "默认应挂生成的入口")


## 骨架幂等 + 不覆盖手写文件。
func test_ensure_project_idempotent_and_respects_handwritten() -> void:
	_clean_probe()
	var abs := ProjectSettings.globalize_path(PROBE)
	var src := abs.path_join("addons/P/Native/src")
	DirAccess.make_dir_recursive_absolute(src)
	_write(src.path_join("p.h"), "class PNode : public Node {\n\tGDCLASS(PNode, Node)\n};\n")
	_write(src.path_join("p.cpp"), "#include \"p.h\"\n")
	_write(src.path_join("register_types.cpp"), "// 手写入口\n")
	var r1: Dictionary = SCAFFOLD.ensure_project(abs, "4.7", false)
	assert_true((r1.get("created", []) as Array).size() > 0, "首次应生成骨架")
	var r2: Dictionary = SCAFFOLD.ensure_project(abs, "4.7", false)
	assert_true((r2.get("created", []) as Array).is_empty(), "第二次运行不应再写任何文件(幂等)")
	assert_false(FileAccess.file_exists(abs.path_join("gdextension/generated/P_register_types.cpp")),
			"插件自带 register_types.cpp 时不应再生成入口")
	# 手写 CMakeLists(去掉生成标记) → 不接管, 也不产生 generated/*
	_write(abs.path_join("gdextension/CMakeLists.txt"), "# my own build\nadd_library(P SHARED x)\n")
	var r3: Dictionary = SCAFFOLD.ensure_project(abs, "4.7", false)
	assert_true((r3.get("created", []) as Array).is_empty(), "手写构建文件不应被改写")
	assert_eq(FileAccess.get_file_as_string(abs.path_join("gdextension/CMakeLists.txt")), "# my own build\nadd_library(P SHARED x)\n", "内容必须原样保留")
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
