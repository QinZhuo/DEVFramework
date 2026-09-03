@tool
class_name GDExtensionRebuild
extends EditorScript

## 通用 GDExtension 一键构建工具 —— 零配置、零移动，支持任何遵循 godot-cpp 生态约定的扩展。
##
## 自动出现在 项目 → 工具 → EditorScript（EditorScriptMenuTool 扫描注册）。
## 一次运行自动完成: 发现扩展工程 → 读 CMakeLists 与 *.gdextension 分辨"如何构建/产物去哪"
## → CMake 配置(必要时)/异步编译(不卡编辑器, 实时回显) → 产物按规格改名部署。
##
## 三条"事实源", 不猜:
##   1) CMakeCache.txt(已配置过): 生成器/编译器/API 全以缓存为准, 只 cmake --build;
##   2) CMakeLists.txt(无缓存需配置时): 只扫三个高可信 token ——
##        add_library(<name> SHARED)          认产物名(替代模糊找库)
##        *_OUTPUT_DIRECTORY = <字面路径>     产物直出目录(加为搜索根)
##        set(GODOTCPP_API_VERSION "x.y")     有默认则不再传 -D(尊重工程钉的绑定版本)
##      其余(条件/生成器/编译器)交给 cmake 自身, 不做 CMake 语义解释;
##   3) *.gdextension [libraries]: 当前 平台.类型[.架构] 键 = 产物最终文件名与落点(部署规格)。
##
## 其余自动判定: 源码目录(唯一工程根 res://gdextension, 多个 addons 候选按规格配对);
## 构建类型 debug/release 跟随当前编辑器; 生成器探测 ninja 否则交给 cmake。
## 已知边界(引擎层面): 编辑器只在启动时加载扩展, 编译后需 项目→重新加载当前项目 生效;
## Windows 上编辑器锁住正在加载的 dll 会致覆盖失败, 工具会打印手动复制指引。发布由 CI 负责。

static var _me: GDExtensionRebuild   # 异步构建期间持有自身(菜单调用方不持有实例)

var _lines: Array[String] = []


func _run() -> void:
	_me = self
	_log("━━━━ GDExtension 一键构建 ━━━━")
	var loc := _locate()
	if loc.is_empty():
		return _finish()
	var source_dir: String = loc.get("source")
	var ext_file: String = loc.get("extension")
	var target_res := _parse_library_target(ext_file)
	if target_res.is_empty():
		return _finish()
	_log("源码工程: ", source_dir)
	_log("规格文件: ", ext_file)
	_log("本机产物落点: ", target_res)

	if not _precheck(source_dir):
		return _finish()
	var build_dir := _pick_build_dir(source_dir)
	if build_dir.is_empty():
		return _finish()
	var info := _read_cmake_info(source_dir, build_dir)
	if not _ready_build_dir(build_dir, source_dir, info):
		return _finish()
	var ok := await _build(build_dir)
	if not ok:
		return _finish()
	_deploy(build_dir, target_res, info)
	_log("构建完成。需 项目→重新加载当前项目 生效(引擎启动时才加载扩展)。")
	_finish()


# ------------------------------------------------------------ 零配置定位

## 源码目录: res://gdextension 唯一工程根; 多个 addons 候选时按规格文件归属配对
func _locate() -> Dictionary:
	var dirs := discover_source_dirs()
	if dirs.is_empty():
		_log("未发现 GDExtension 工程。请确认 res://gdextension(或 addons/*/) 含 CMakeLists.txt + godot-cpp/ submodule。")
		return {}
	var ext_order: Array[String] = []
	var seen := {}
	for d in dirs:
		for e in find_extension_files(d):
			if not seen.has(e):
				seen[e] = true
				ext_order.append(e)
	if ext_order.is_empty():
		_log("未找到 *.gdextension 规格文件(常见位置: addons/**/Native、addons/**、bin)。")
		return {}
	var want := "%s.%s.%s" % [_os_label(), _build_type(), _arch()]
	var want_short := "%s.%s" % [_os_label(), _build_type()]
	var runnable: Array[String] = []
	for e in ext_order:
		var keys := _parse_library_keys(e)
		if keys.has(want) or keys.has(want_short):
			runnable.append(e)
	var pool: Array[String] = runnable if not runnable.is_empty() else ext_order
	var ext_file: String = pool[0]
	var newest := -1.0
	for e in pool:
		var m := FileAccess.get_modified_time(e)
		if m > newest:
			newest = m
			ext_file = e
	var source_dir: String = dirs[0]
	if dirs.size() > 1:
		var by_ext := _source_matching_addon(ext_file, dirs)
		if by_ext != "":
			source_dir = by_ext
		else:
			_log("多个工程目录且无法判定归属, 默认取: ", source_dir)
			for d in dirs:
				_log("    - 候选: ", d)
	if dirs.size() > 1 or ext_order.size() > 1:
		_log("已选择: ", source_dir, " + ", ext_file)
		if not runnable.is_empty() and runnable.size() < ext_order.size():
			_log("其余规格无本机(", want, ")条目, 已忽略。")
	return {"source": source_dir, "extension": ext_file}


## 规格文件位于某个"同样是工程候选"的 addons 目录下时, 判定归属
static func _source_matching_addon(ext_file: String, dirs: Array) -> String:
	var parts := ext_file.split("/", false)
	if parts.size() >= 3 and parts[1] == "addons":
		var addon_dir := "res://addons/%s" % parts[2]
		for d in dirs:
			if d == addon_dir:
				return d
	return ""


## 自动发现工程目录候选(静态, 供外部/MCP 复用): 项目根 gdextension/ + 各 addons/*/
static func discover_source_dirs() -> Array[String]:
	var out: Array[String] = []
	if _is_ext_source("res://gdextension"):
		out.append("res://gdextension")
	var addons := DirAccess.open("res://addons")
	if addons:
		addons.list_dir_begin()
		var entry := addons.get_next()
		while entry != "":
			if addons.current_is_dir() and not entry.begins_with("."):
				var cand := "res://addons/%s" % entry
				if _is_ext_source(cand):
					out.append(cand)
			entry = addons.get_next()
		addons.list_dir_end()
	return out


static func _is_ext_source(dir_path: String) -> bool:
	var has_build := FileAccess.file_exists(dir_path.path_join("CMakeLists.txt")) \
			or FileAccess.file_exists(dir_path.path_join("SConstruct"))
	var has_cpp := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path.path_join("godot-cpp")))
	return has_build and has_cpp


## 自动收集 *.gdextension(静态, 供外部/MCP 复用): 工程目录内/bin + addons/**/Native + addons/**
static func find_extension_files(source_dir: String) -> Array[String]:
	var found: Array[String] = []
	var seen := {}
	for probe in [source_dir, source_dir.path_join("bin")]:
		_collect_ext(probe, found, seen, 0)
	_collect_ext("res://addons", found, seen, 3)
	found.sort()
	return found


static func _collect_ext(dir_path: String, out: Array[String], seen: Dictionary, depth: int) -> void:
	if depth < 0 or seen.has(dir_path):
		return
	seen[dir_path] = true
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			if depth > 0:
				_collect_ext(full, out, seen, depth - 1)
			elif entry in ["Native", "bin"]:
				_collect_ext(full, out, seen, 1)
		elif entry.ends_with(".gdextension"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


## 解析 [libraries] 中当前 平台.类型[.架构] 键 → res:// 落点; 键缺失给出清单
func _parse_library_target(ext_file: String) -> String:
	var keys := _parse_library_keys(ext_file)
	var want := "%s.%s.%s" % [_os_label(), _build_type(), _arch()]
	var want_short := "%s.%s" % [_os_label(), _build_type()]
	for try_key in [want, want_short]:
		if keys.has(try_key):
			return keys[try_key]
	_log("规格文件中缺少本机条目 ", want, "(或 ", want_short, "), 现有条目:")
	for k in keys:
		_log("    - ", k, " = ", keys[k])
	return ""


## 解析 .gdextension 的 [libraries] 段(静态, 供外部/MCP 复用)
static func _parse_library_keys(ext_file: String) -> Dictionary:
	var keys := {}
	var f := FileAccess.open(ext_file, FileAccess.READ)
	if f == null:
		return keys
	var in_libraries := false
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("["):
			in_libraries = line.to_lower().begins_with("[libraries]")
			continue
		if not in_libraries or line == "" or line.begins_with(";"):
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		var key := line.substr(0, eq).strip_edges()
		var val := line.substr(eq + 1).strip_edges().trim_prefix('"').trim_suffix('"')
		if key != "" and val != "":
			keys[key] = val
	f.close()
	return keys


# ------------------------------------------------------------ 读 CMakeLists 分辨"如何构建"(三个高可信 token)

## 返回 {target, out_dirs(绝对), api_default}。不解释 CMake 语义, 只扫模板级高可信写法;
## 扫不到任何 token 也不报错 —— 交由缓存/默认/模糊找库兜底。
func _read_cmake_info(project_dir: String, build_dir: String) -> Dictionary:
	var info := {target = "", out_dirs = [], api_default = ""}
	var cmake_path := _abs(project_dir).path_join("CMakeLists.txt")
	if not FileAccess.file_exists(cmake_path):
		return info
	var text := FileAccess.get_file_as_string(cmake_path)

	var re_target := RegEx.new()
	re_target.compile("add_library\\s*\\(\\s*([A-Za-z_][A-Za-z0-9_]*)")
	var m := re_target.search(text)
	if m:
		info.target = m.get_string(1)

	var re_out := RegEx.new()
	re_out.compile("(?:LIBRARY|RUNTIME|ARCHIVE)_OUTPUT_DIRECTORY\\s+([^\\s#]+)")
	var out_set := {}
	for om in re_out.search_all(text):
		var raw: String = om.get_string(1).trim_prefix('"').trim_suffix('"')
		if raw.is_empty() or raw.contains("${CMAKE_CURRENT_BINARY_DIR}"):
			continue
		var expanded := raw.replace("${CMAKE_CURRENT_SOURCE_DIR}", _abs(project_dir))
		var normalized := _normalize_abs(expanded)
		if not normalized.is_empty() and not out_set.has(normalized):
			out_set[normalized] = true
			info.out_dirs.append(normalized)

	var re_api := RegEx.new()
	re_api.compile("set\\s*\\(\\s*GODOTCPP_API_VERSION\\s+(?:\"([0-9.]+)\"|([0-9.]+))")
	var am := re_api.search(text)
	if am:
		info.api_default = am.get_string(1) if am.get_string(1) != "" else am.get_string(2)
	return info


## 规范化绝对路径(展开 .. 与 .), 支持 Windows "C:/..." 与 POSIX "/..."
func _normalize_abs(path: String) -> String:
	path = path.replace("\\", "/")
	var is_win := path.length() > 2 and path[1] == ":"
	var drive := path.substr(0, 2) if is_win else ""
	var rest := path.substr(2) if is_win else path
	if not is_win and not rest.begins_with("/"):
		return ""
	var stack: Array[String] = []
	for p in rest.split("/"):
		if p == "..":
			if not stack.is_empty():
				stack.pop_back()
		elif p != "" and p != ".":
			stack.append(p)
	var joined := "/".join(stack)
	return ("%s/%s" % [drive, joined]) if is_win else ("/" + joined)


# ------------------------------------------------------------ 工具链探测与构建目录

func _precheck(source_dir: String) -> bool:
	var abs := _abs(source_dir)
	if not FileAccess.file_exists(abs.path_join("CMakeLists.txt")):
		_log("该扩展暂仅支持 CMake 构建(未找到 CMakeLists.txt)。")
		return false
	if not FileAccess.file_exists(abs.path_join("godot-cpp/SConstruct")):
		_log("godot-cpp submodule 未初始化, 请先执行:")
		_log("    git submodule update --init --recursive")
		return false
	var out: Array = []
	if OS.execute("cmake", ["--version"], out, true) != 0:
		_log("未找到 cmake, 请安装并加入 PATH(Windows 便携版可参考 w64devkit)。")
		return false
	var ver: String = (out[0] if not out.is_empty() else "").strip_edges().split("\n")[0]
	_log("cmake: ", ver)
	return true


## 构建目录: 工程下 build*(CMakeCache) 优先; 没有则用 .godot/gdextension_build/(不污染工程目录)
func _pick_build_dir(source_dir: String) -> String:
	var src_abs := _abs(source_dir)
	var token := _os_token()
	var in_tree: Array[String] = []
	var in_tree_ok: Array[String] = []
	var dir := DirAccess.open(src_abs)
	if dir:
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			if dir.current_is_dir() and entry.begins_with("build"):
				var full := src_abs.path_join(entry)
				if FileAccess.file_exists(full.path_join("CMakeCache.txt")):
					in_tree.append(full)
					if entry.to_lower().contains(token):
						in_tree_ok.append(full)
			entry = dir.get_next()
		dir.list_dir_end()
	if not in_tree_ok.is_empty():
		return _newest_cache(in_tree_ok)
	if not in_tree.is_empty():
		return _newest_cache(in_tree)
	var cache_root := _abs("res://.godot/gdextension_build")
	var cached: Array[String] = []
	var cdir := DirAccess.open(cache_root)
	if cdir:
		cdir.list_dir_begin()
		var entry := cdir.get_next()
		while entry != "":
			if cdir.current_is_dir():
				var full := cache_root.path_join(entry)
				if FileAccess.file_exists(full.path_join("CMakeCache.txt")):
					cached.append(full)
			entry = cdir.get_next()
		cdir.list_dir_end()
	if not cached.is_empty():
		return _newest_cache(cached)
	var fresh := cache_root.path_join("%s-%s-%s" % [source_dir.get_file(), _os_label(), _arch()])
	_log("未发现已配置构建目录, 将新建: ", fresh)
	return fresh


static func _newest_cache(dirs: Array) -> String:
	var best := String(dirs[0])
	var t := -1.0
	for d in dirs:
		var m := FileAccess.get_modified_time(String(d).path_join("CMakeCache.txt"))
		if m > t:
			t = m
			best = String(d)
	return best


func _ready_build_dir(build_dir: String, source_dir: String, info: Dictionary) -> bool:
	if FileAccess.file_exists(build_dir.path_join("CMakeCache.txt")):
		_log("复用构建目录(以缓存配置为准): ", build_dir)
		return true
	var src_abs := _abs(source_dir)
	DirAccess.make_dir_recursive_absolute(build_dir)
	var args: PackedStringArray = ["-S", src_abs, "-B", build_dir]
	var generator := _detect_generator()
	if generator != "":
		args.append_array(["-G", generator])
	# CMakeLists 自带 GODOTCPP_API_VERSION 默认值 → 不传 -D, 尊重工程钉的绑定版本; 否则用引擎版本
	var api_default: String = info.get("api_default", "")
	var api := api_default
	if api == "":
		var vi: Dictionary = Engine.get_version_info()
		api = "%d.%d" % [int(vi.get("major", 4)), int(vi.get("minor", 0))]
		args.append("-DGODOTCPP_API_VERSION=%s" % api)
	args.append("-DCMAKE_BUILD_TYPE=%s" % _build_type_cap())
	_log("配置 CMake: ", " ".join(args))
	var out: Array = []
	var code := OS.execute("cmake", args, out, true)
	_print_out(out)
	if code != 0:
		_log("cmake 配置失败(退出码 %d)。Windows 常见原因: MinGW 未在 PATH, 或用 MSVC 但编辑器非从 vcvars 环境启动。" % code)
		return false
	return true


func _detect_generator() -> String:
	var out: Array = []
	return "Ninja" if OS.execute("ninja", ["--version"], out) == 0 else ""


# ------------------------------------------------------------ 异步构建

func _build(build_dir: String) -> bool:
	var type := _build_type()
	_log("开始编译 (", type, ")…… 编辑器保持可用, 输出实时回显。")
	var args := ["--build", build_dir, "--config", type.capitalize()]
	var pipe: Dictionary = OS.execute_with_pipe("cmake", PackedStringArray(args), false)
	var pid: int = int(pipe.get("pid", 0))
	var stdout: Variant = pipe.get("stdout")
	var stderr: Variant = pipe.get("stderr")
	if pid <= 0:
		_log("execute_with_pipe 不可用, 退化为阻塞执行(编辑器会卡住直到完成)。")
		var out: Array = []
		var code := OS.execute("cmake", PackedStringArray(args), out, true)
		_print_out(out)
		return code == 0
	var tree := Engine.get_main_loop() as SceneTree
	while OS.is_process_running(pid):
		_drain(stdout)
		_drain(stderr)
		await tree.create_timer(0.2).timeout
	_drain(stdout)
	_drain(stderr)
	var exit_code := OS.get_process_exit_code(pid)
	if stdout is FileAccess:
		(stdout as FileAccess).close()
	if stderr is FileAccess:
		(stderr as FileAccess).close()
	if exit_code == 0:
		_log("编译成功。")
	else:
		_log("编译失败(退出码 %d), 请按上方报错定位。" % exit_code)
	return exit_code == 0


func _drain(pipe) -> void:
	if pipe == null or not (pipe is FileAccess):
		return
	var fa := pipe as FileAccess
	if fa.get_length() <= fa.get_position():
		return
	var text := fa.get_as_text()
	if text != "":
		_log_raw(text)


# ------------------------------------------------------------ 部署: 找产物 → 按规格键改名放入落点

func _deploy(build_dir: String, target_res: String, info: Dictionary) -> void:
	var roots: Array[String] = [build_dir]
	for d in info.get("out_dirs", []):
		roots.append(String(d))
	var target_dir_abs := _abs(target_res).get_base_dir()
	if not roots.has(target_dir_abs):
		roots.append(target_dir_abs)
	var artifact := _find_artifact(roots, String(info.get("target", "")))
	if artifact.is_empty():
		_log("未定位到产物, 请检查上方编译输出。")
		return
	var target_abs := _abs(target_res)
	if artifact == target_abs:
		_log("产物已就位(直出目标目录): ", target_abs)
		return
	DirAccess.make_dir_recursive_absolute(target_abs.get_base_dir())
	_log("产物: ", artifact)
	if _copy_binary(artifact, target_abs):
		_log("已部署: ", target_res)
		return
	_log("覆盖目标失败: ", target_abs)
	if OS.get_name() == "Windows":
		_log("原因通常是编辑器正加载该 dll(Windows 文件锁)。请关闭编辑器后手动复制:")
	else:
		_log("请检查目标目录权限后重试, 或手动复制:")
	_log("    copy  \"%s\"  →  \"%s\"" % [artifact, target_abs])


## 在多个搜索根里找"名字匹配 CMake 目标"的最新共享库(跳过 godot-cpp 中间产物)
func _find_artifact(roots: Array, target: String) -> String:
	var stems := PackedStringArray()
	if target != "":
		stems.append(target)
		stems.append("lib" + target)
	var found: Array[String] = []
	for r in roots:
		_walk_artifact(String(r), 0, stems, found)
	if found.is_empty():
		return ""
	found.sort_custom(func(a: String, b: String) -> bool:
		return FileAccess.get_modified_time(a) > FileAccess.get_modified_time(b))
	return found[0]


func _walk_artifact(dir_path: String, depth: int, stems: PackedStringArray, out: Array[String]) -> void:
	if depth > 3:
		return
	if dir_path.to_lower().ends_with("godot-cpp"):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			_walk_artifact(full, depth + 1, stems, out)
		elif entry.ends_with(".dll") or entry.ends_with(".so") or entry.ends_with(".dylib"):
			var ok_stem := stems.is_empty()
			if not ok_stem:
				var stem := entry.get_basename()
				for s in stems:
					if stem == s:
						ok_stem = true
						break
			if ok_stem:
				out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


# ------------------------------------------------------------ 平台信息

func _os_label() -> String:
	match OS.get_name():
		"Windows": return "windows"
		"macOS", "OSX": return "macos"
		"Linux": return "linux"
		_: return OS.get_name().to_lower()


func _arch() -> String:
	var arch := Engine.get_architecture_name().to_lower()
	return "x86_64" if arch == "universal" else arch


func _os_token() -> String:
	match OS.get_name():
		"Windows": return "win"
		"macOS", "OSX": return "mac"
		"Linux": return "linux"
	return _os_label()


## 构建类型跟随当前编辑器(debug 编辑器 → debug 产物, 与 .gdextension 键对应)
func _build_type() -> String:
	return "debug" if OS.is_debug_build() else "release"


func _build_type_cap() -> String:
	return _build_type().capitalize()


# ------------------------------------------------------------ 小工具

func _res(p: String) -> String:
	if p.begins_with("res://"):
		return p
	return "res://%s" % p.trim_prefix("/")


func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(_res(p))


## 字节级复制(失败返回 false 由调用方给指引)
func _copy_binary(src: String, dst: String) -> bool:
	var f_in := FileAccess.open(src, FileAccess.READ)
	if f_in == null:
		return false
	var data := f_in.get_buffer(f_in.get_length())
	f_in.close()
	if data.is_empty():
		return false
	var f_out := FileAccess.open(dst, FileAccess.WRITE)
	if f_out == null:
		return false
	f_out.store_buffer(data)
	f_out.close()
	return true


func _print_out(out: Array) -> void:
	for line in out:
		_log_raw(String(line))


func _log(...parts) -> void:
	_log_raw(" ".join(parts.map(str)))


func _log_raw(text: String) -> void:
	_lines.append(text)
	print(text)


func _finish() -> void:
	_log("━━━━ 完成(共 %d 行输出) ━━━━" % _lines.size())
	_me = null
