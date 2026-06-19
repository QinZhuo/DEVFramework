@tool
class_name DevProjectSetup

static var _project_dirs: PackedStringArray = [
	"res://Audio/",
	"res://Def/",
	"res://Def/Actor/",
	"res://Def/Attribute/",
	"res://Def/Buff/",
	"res://Def/Signal/",
	"res://Def/Tag/",
	"res://Def/Translation/",
	"res://View/Actor/",
	"res://View/Font/",
	"res://Script/",
	"res://Script/Def/",
	"res://Script/Def/Condition/",
	"res://Script/Def/Effect/",
	"res://Script/Def/Signal/",
	"res://Script/Def/Tag/",
	"res://Script/Def/Value/",
	"res://Script/Entity/",
	"res://Script/View/",
]

static func create_structure() -> void:
	var dir = DirAccess.open("res://")
	if not dir:
		printerr("DevProjectSetup: 无法打开 res://")
		return

	var created_count := 0
	var existed_count := 0
	var error_count := 0

	for sub_path in _project_dirs:
		print("新建文件夹", sub_path)
		if dir.dir_exists(sub_path):
			existed_count += 1
			continue

		var ok = dir.make_dir_recursive(sub_path)
		if ok == OK:
			created_count += 1
		else:
			printerr("DevProjectSetup: 创建失败 [%s] (错误码: %d)" % [sub_path, ok])
			error_count += 1

	print("DevProjectSetup: 完成！新建 %d 个文件夹，已存在 %d 个，失败 %d 个。" % [created_count, existed_count, error_count])
