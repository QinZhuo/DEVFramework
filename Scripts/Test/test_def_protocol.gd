extends TestCase

## Def 的"路径即身份"契约（LAYERS §七）。存档里存的是相对 `res://Assets/Def/` 的短路径，
## 因此这条链断了就是**玩家存档坏掉**：路径拼接、旧格式兼容、找不到时的兜底，三者都要锁住。
##
## 用仓库里真实存在的资源做夹具，不造临时 .tres —— 造的文件一旦忘了清理，会污染后续用例。

const FIXTURE_REL := "Changelog/ChangelogExample.tres"
const FIXTURE_ABS := "res://Assets/Def/Changelog/ChangelogExample.tres"


func test_save_data_is_relative_path() -> void:
	var d := Def.load_data(FIXTURE_ABS)
	assert_true(d != null, "夹具资源应能加载")
	assert_eq(d.save_data(), FIXTURE_REL, "存档值必须是相对 Assets/Def 的短路径")


func test_roundtrip_save_then_load() -> void:
	var d := Def.load_data(FIXTURE_ABS)
	var restored := Def.load_data(d.save_data())
	assert_true(restored == d, "短路径应能还原成同一个资源")


## 旧存档里存的是完整 `res://` 路径，必须继续能读 —— 否则升级一次就废掉所有老档。
func test_load_data_accepts_legacy_full_path() -> void:
	var d := Def.load_data(FIXTURE_ABS)
	assert_true(d != null, "完整路径格式(旧存档)必须兼容")


func test_load_data_missing_returns_null() -> void:
	assert_true(Def.load_data("Changelog/NoSuchDef.tres") == null,
			"资源不存在时必须返回 null，不能抛错也不能返回空 Def")
	assert_true(Def.load_data("res://Assets/Def/Changelog/NoSuchDef.tres") == null,
			"完整路径不存在同样返回 null")


func test_name_follows_file_name() -> void:
	var d := Def.load_data(FIXTURE_ABS)
	assert_eq(d.name, "ChangelogExample", "name 取文件名(不含扩展名)，是 Def 的稳定标识")


func test_root_def_is_self_when_not_builtin() -> void:
	var d := Def.load_data(FIXTURE_ABS)
	assert_true(d.get_root_def() == d, "非内嵌资源的主 Def 就是它自己")


func test_entity_def_save_value_is_stable_string() -> void:
	var d := Def.load_data(FIXTURE_ABS)
	var v: Variant = d.save_data()
	assert_true(v is String, "save_data 必须返回字符串(路径)，不能是资源引用")
	assert_false(str(v).begins_with("res://"), "存档值不应含前缀，否则 DLC 覆盖后路径对不上")
