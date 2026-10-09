extends TestCase

## FileTool / SaveTool 落盘契约回归。
##
## 锁定两类曾存在的静默缺陷:
## 1) 原子写入: 首写 / 覆盖写内容正确、不残留 .tmp —— 覆盖语义依赖平台 rename, 必须实际验证;
## 2) SaveTool.save_async 的落盘路径必须与同步 save_data 一致(曾因 _write_file 硬编码 GZIP 哈希,
##    导致 BYTES 异步保存写到另一个文件, 表现为"保存成功却读不到新档")。

const _BASE := "user://_test_filetool"


func cleanup() -> void:
	_remove_dir_recursive(_BASE)


func test_filetool_atomic_overwrite() -> void:
	var p := _BASE + "/atomic.txt"
	assert_eq(FileTool.atomic_write_text(p, "one"), OK, "首次原子写应成功")
	assert_eq(FileTool.read_text(p), "one", "原子写内容应可读回")
	assert_eq(FileTool.atomic_write_text(p, "two-longer"), OK, "覆盖写应成功")
	assert_eq(FileTool.read_text(p), "two-longer", "覆盖写后内容应为新值")
	assert_false(FileAccess.file_exists(p + ".tmp"), "原子写完成后不应残留 .tmp")


func test_save_sync_modes_roundtrip() -> void:
	var p := _BASE + "/sync"
	var dict := {"a": 1.0, "b": [1.0, 2.0, 3.0]}

	assert_eq(SaveTool.save_data(p, dict, SaveTool.Mode.JSON), OK, "JSON 保存应成功")
	assert_eq(SaveTool.load_data(p, SaveTool.Mode.JSON), dict, "JSON 往返应一致")

	assert_eq(SaveTool.save_data(p, dict, SaveTool.Mode.GZIP), OK, "GZIP 保存应成功")
	assert_eq(SaveTool.load_data(p, SaveTool.Mode.GZIP), dict, "GZIP 往返应一致")

	var bytes := PackedByteArray([1, 2, 3, 250, 0, 9])
	assert_eq(SaveTool.save_data(p, bytes, SaveTool.Mode.BYTES), OK, "BYTES 保存应成功")
	assert_eq(SaveTool.load_data(p, SaveTool.Mode.BYTES), bytes, "BYTES 往返应一致")


## 异步 BYTES: 必须落在与同步路径相同的文件上(回归: 曾错位到 sha256 哈希名)
func test_save_async_bytes_same_path() -> void:
	var p := _BASE + "/async_bytes"
	var bytes := PackedByteArray([7, 7, 7, 200])

	assert_eq(await SaveTool.save_async(p, bytes, SaveTool.Mode.BYTES), OK, "异步 BYTES 保存应成功")
	assert_true(SaveTool.file_exists(p, SaveTool.Mode.BYTES), "异步保存后 BYTES 档应存在于常规路径")
	assert_eq(SaveTool.load_data(p, SaveTool.Mode.BYTES), bytes, "异步 BYTES 存/读往返应一致")


func test_save_async_gzip_roundtrip() -> void:
	var p := _BASE + "/async_gzip"
	var dict := {"x": 2.5, "y": [10.0, 20.0]}

	assert_eq(await SaveTool.save_async(p, dict, SaveTool.Mode.GZIP), OK, "异步 GZIP 保存应成功")
	assert_eq(SaveTool.load_data(p, SaveTool.Mode.GZIP), dict, "异步 GZIP 往返应一致")


static func _remove_dir_recursive(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			_remove_dir_recursive(dir_path.path_join(entry))
		else:
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(dir_path)
