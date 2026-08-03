@tool
## 音符序列定义 — 显式排列一串音符，适合手工编写固定旋律/音效
class_name AudioPatternDef extends Def

@export_range(0, 128, 1) var voice_index := 0
@export_range(20.0, 400.0, 0.5) var bpm := 120.0
@export var notes: Array[AudioNoteDef] = []

## 每拍拍号（默认 4/4）
@export_range(1, 12, 1) var beats_per_bar := 4

func get_desc(_data) -> String:
	return "%d 音符 @%gBPM" % [notes.size(), bpm]

func _to_string() -> String:
	return "Pattern[%d, %gBPM]" % [notes.size(), bpm]