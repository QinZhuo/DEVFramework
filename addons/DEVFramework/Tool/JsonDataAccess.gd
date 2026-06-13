## JSON 文件工具 - 提供 JSON 文件的读写操作
class_name JsonDataAccess

static func check_version(data: Variant, version: String, ignore_patch: bool = false) -> Variant:
	if not data or not data.has("version"):
		return {}
	var data_version: String = data.version
	if ignore_patch:
		var prefix := version.rsplit(".", true, 1)[0]
		var data_prefix := data_version.rsplit(".", true, 1)[0]
		if prefix != data_prefix:
			return {}
	else:
		if data_version != version:
			return {}
	return data

## 保存数据到 JSON 文件
static func save_data(path: String, data) -> Error:
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()
		return OK
	else:
		push_error("无法打开文件进行写入: ", path)
		return FAILED

## 从 JSON 文件加载数据
static func load_data(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_warning(path, " 存档文件不存在，返回默认数据")
		return {}
	var file = FileAccess.open(path, FileAccess.READ)
	if file:
		var json_string = file.get_as_text()
		file.close()
		var json = JSON.new()
		var parse_result = json.parse(json_string)
		if parse_result == OK:
			return json.data
		else:
			push_error("JSON 解析错误: ", json.get_error_message(), " 行: ", json.get_error_line())
			return {}
	else:
		push_error("无法打开文件进行读取: ", path)
		return {}
