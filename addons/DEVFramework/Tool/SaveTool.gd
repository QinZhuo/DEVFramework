## 存档工具 - 提供加解密 / JSON 文件的读写操作
## 加密基于 Godot 内置 FileAccess.open_encrypted_with_pass (AES-256-PBKDF2)
## 注：加密 Key 由项目名 + 项目设置中的 salt 组合生成，目的不是防解密，而是增加手动修改存档的成本
## 可在 项目 → 项目设置 → dev_framework → save_tool → encrypt_salt 中修改 salt 值
class_name SaveTool

enum EncryptMode {
	NONE, # 不加密，直接读写 JSON
	DATA_ONLY, # 加密数据内容，文件名保持原样
	DATA_AND_FILENAME, # 加密数据内容 + 文件名（文件名用 SHA256 哈希）
}

const _SALT_SETTING := "dev_framework/save_tool/encrypt_salt"
const _SALT_DEFAULT := "SaveTool"


## 从项目设置读取 salt，与项目名组合生成密码
static func _get_pass() -> String:
	var salt := _SALT_DEFAULT
	if ProjectSettings.has_setting(_SALT_SETTING):
		salt = str(ProjectSettings.get_setting(_SALT_SETTING))
	var pname := ProjectSettings.get_setting("application/config/name", "GodotProject")
	return salt + str(pname)


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


## 保存数据，支持 3 种加密模式
static func save_data(path: String, data, mode: EncryptMode = EncryptMode.NONE) -> Error:
	var actual_path := _resolve_path(path, mode)
	var dir := actual_path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var json_str := JSON.stringify(data, "\t")

	if mode == EncryptMode.NONE:
		var file = FileAccess.open(actual_path, FileAccess.WRITE)
		if not file:
			LogTool.error("存档", "无法打开文件:", actual_path)
			return FAILED
		file.store_string(json_str)
		file.close()
		return OK

	# 加密模式：使用 Godot 内置 AES-256 加密文件
	var file = FileAccess.open_encrypted_with_pass(actual_path, FileAccess.WRITE, _get_pass())
	if not file:
		LogTool.error("存档", "无法打开加密文件:", actual_path)
		return FAILED
	file.store_string(json_str)
	file.close()

	# 编辑器下额外保存一份未加密副本，方便调试查看
	if OS.has_feature("editor"):
		var df := FileAccess.open(path, FileAccess.WRITE)
		if df:
			df.store_string(json_str)
			df.close()

	return OK


## 加载数据，自动识别加密模式
static func load_data(path: String, mode: EncryptMode = EncryptMode.NONE) -> Variant:
	var actual_path := _resolve_path(path, mode)
	if not FileAccess.file_exists(actual_path):
		return {}

	var json_string: String

	if mode == EncryptMode.NONE:
		var file = FileAccess.open(actual_path, FileAccess.READ)
		if not file:
			LogTool.error("存档", "无法打开文件:", actual_path)
			return {}
		json_string = file.get_as_text()
		file.close()
	else:
		# 加密模式：使用 Godot 内置解密读取
		var file = FileAccess.open_encrypted_with_pass(actual_path, FileAccess.READ, _get_pass())
		if not file:
			LogTool.error("存档", "无法打开加密文件(密码错误/文件损坏):", actual_path)
			return {}
		json_string = file.get_as_text()
		file.close()

	var json := JSON.new()
	var parse_result := json.parse(json_string)
	if parse_result == OK:
		return json.data
	LogTool.error("存档", "JSON 解析错误:", json.get_error_message())
	return {}


## 检查文件是否存在（自动处理加密路径解析）
static func file_exists(path: String, mode: EncryptMode = EncryptMode.NONE) -> bool:
	return FileAccess.file_exists(_resolve_path(path, mode))


## 删除存档（自动处理加密路径解析）
static func delete_data(path: String, mode: EncryptMode = EncryptMode.NONE) -> Error:
	var actual_path := _resolve_path(path, mode)
	var deleted := false
	if FileAccess.file_exists(actual_path):
		var err := DirAccess.remove_absolute(actual_path)
		if err != OK:
			LogTool.error("存档", "删除文件失败:", actual_path, "错误:", err)
			return err
		deleted = true
	# 编辑器下 debug 副本一并删除
	if OS.has_feature("editor") and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return OK if deleted else FAILED


# ============================================================
# 内部：路径解析 / 哈希
# ============================================================

## 根据加密模式解析实际文件路径
static func _resolve_path(path: String, mode: EncryptMode) -> String:
	if mode == EncryptMode.DATA_AND_FILENAME:
		var hash := _sha256(path)
		return path.get_base_dir().path_join(hash)
	return path


## SHA-256 哈希（用于文件名加密）
static func _sha256(input: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(input.to_utf8_buffer())
	return ctx.finish().hex_encode()
