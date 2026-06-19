## 通用日志工具 — 标签标记、自动配色、项目设置集成
class_name LogTool

const SETTING_ENABLED  := "dev_framework/log/enabled"
const SETTING_TIMESTAMPS := "dev_framework/log/show_timestamps"
const SETTING_IGNORED_TAGS := "dev_framework/log/ignored_tags"

enum Level { LOG, WARN, ERROR }


static func set_enabled(v: bool) -> void:
	ProjectSettings.set_setting(SETTING_ENABLED, v)

static func set_show_timestamps(v: bool) -> void:
	ProjectSettings.set_setting(SETTING_TIMESTAMPS, v)

static func disable_tag(tag: String) -> void:
	var ignored: PackedStringArray = ProjectSettings.get_setting(SETTING_IGNORED_TAGS, PackedStringArray())
	if tag not in ignored:
		ignored.append(tag)
		ProjectSettings.set_setting(SETTING_IGNORED_TAGS, ignored)

static func enable_tag(tag: String) -> void:
	var ignored: PackedStringArray = ProjectSettings.get_setting(SETTING_IGNORED_TAGS, PackedStringArray())
	var idx := ignored.find(tag)
	if idx >= 0:
		ignored.remove_at(idx)
		ProjectSettings.set_setting(SETTING_IGNORED_TAGS, ignored)


static func log(tag: String, ...objs: Array) -> void:
	_out(Level.LOG, tag, objs)

static func warn(tag: String, ...objs: Array) -> void:
	_out(Level.WARN, tag, objs)

static func error(tag: String, ...objs: Array) -> void:
	_out(Level.ERROR, tag, objs)


static func _out(level: Level, tag: String, objs: Array) -> void:
	var ignored: PackedStringArray = ProjectSettings.get_setting(SETTING_IGNORED_TAGS, PackedStringArray())
	if (level != Level.ERROR and tag in ignored) or (level != Level.ERROR and not ProjectSettings.get_setting(SETTING_ENABLED, true)):
		return

	var msg := " ".join(objs.map(str))
	var ts := ("%s " % Time.get_time_string_from_system()) if ProjectSettings.get_setting(SETTING_TIMESTAMPS, false) else ""
	match level:
		Level.LOG:
			print_rich(_colored_tag(tag), ts, "[color=#dcdcdc]", msg, "[/color]")
		Level.WARN:
			print_rich(_colored_tag(tag), ts, "[color=#ffc800]", msg, "[/color]")
		Level.ERROR:
			print_rich(_colored_tag(tag), ts, "[color=#ff4040]", msg, "[/color]")


static func _colored_tag(tag: String) -> String:
	var hue: float = fmod(absf(tag.hash()), 360.0) / 360.0
	var c: Color = Color.from_hsv(hue, 0.45, 0.82)
	return "[color=#%s][b][%s][/b][/color]" % [c.to_html(false), tag]