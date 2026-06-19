class_name DevProjectSetup

static var _project_dirs: PackedStringArray = [
	"res://Assets/",
	"res://Assets/Actor/",
	"res://Assets/Audio/",
	"res://Assets/Background/",
	"res://Assets/Def/",
	"res://Assets/Def/Actor/",
	"res://Assets/Def/Affix/",
	"res://Assets/Def/Attribute/",
	"res://Assets/Def/Buff/",
	"res://Assets/Def/Card/",
	"res://Assets/Def/Equip/",
	"res://Assets/Def/GameEvent/",
	"res://Assets/Def/RankTier/",
	"res://Assets/Def/Signal/",
	"res://Assets/Def/Symbol/",
	"res://Assets/Def/Tag/",
	"res://Assets/Def/Tip/",
	"res://Assets/Effect/",
	"res://Assets/Font/",
	"res://Assets/Model/",
	"res://Assets/Render/",
	"res://Assets/Render/Noise/",
	"res://Assets/Render/Shader/",
	"res://Assets/Shader/",
	"res://Assets/Texture/",
	"res://Assets/Translation/",
	"res://Assets/UI/",
	"res://Editor/",
	"res://Scenes/",
	"res://Scenes/Entity/",
	"res://Scenes/Entity/Actor/",
	"res://Scenes/Entity/Game/",
	"res://Scenes/Entity/GameCartridge/",
	"res://Scenes/Entity/GameItems/",
	"res://Scenes/System/",
	"res://Scenes/Temp/",
	"res://Scenes/View/",
	"res://Scenes/View/Audio/",
	"res://Scenes/View/Panel/",
	"res://Scenes/View/Poster/",
	"res://Scenes/View/Tween/",
	"res://Scripts/",
	"res://Scripts/Const/",
	"res://Scripts/Def/",
	"res://Scripts/Def/Condition/",
	"res://Scripts/Def/Effect/",
	"res://Scripts/Def/Signal/",
	"res://Scripts/Def/Tag/",
	"res://Scripts/Def/Value/",
	"res://Scripts/Entity/",
	"res://Scripts/Entity/Component/",
	"res://Scripts/Steam/",
	"res://Scripts/View/",
	"res://Scripts/View/Panel/",
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
