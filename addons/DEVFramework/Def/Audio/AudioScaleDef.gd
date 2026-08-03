@tool
## 音阶定义 — 描述调式与根音，供自动编曲生成音符使用
class_name AudioScaleDef extends Def

enum ScaleType {
	MAJOR,
	NATURAL_MINOR,
	HARMONIC_MINOR,
	MELODIC_MINOR,
	PENTATONIC_MAJOR,
	PENTATONIC_MINOR,
	DORIAN,
	PHRYGIAN,
	LYDIAN,
	MIXOLYDIAN,
	LOCRIAN,
	WHOLE_TONE,
	CHROMATIC,
}

@export_range(0, 127, 1) var root_midi := 60
@export var scale_type: ScaleType = ScaleType.MAJOR

## 各调式的音程（以半音计）
static func get_intervals(type: ScaleType) -> PackedInt32Array:
	match type:
		ScaleType.MAJOR:
			return PackedInt32Array([0, 2, 4, 5, 7, 9, 11])
		ScaleType.NATURAL_MINOR:
			return PackedInt32Array([0, 2, 3, 5, 7, 8, 10])
		ScaleType.HARMONIC_MINOR:
			return PackedInt32Array([0, 2, 3, 5, 7, 8, 11])
		ScaleType.MELODIC_MINOR:
			return PackedInt32Array([0, 2, 3, 5, 7, 9, 11])
		ScaleType.PENTATONIC_MAJOR:
			return PackedInt32Array([0, 2, 4, 7, 9])
		ScaleType.PENTATONIC_MINOR:
			return PackedInt32Array([0, 3, 5, 7, 10])
		ScaleType.DORIAN:
			return PackedInt32Array([0, 2, 3, 5, 7, 9, 10])
		ScaleType.PHRYGIAN:
			return PackedInt32Array([0, 1, 3, 5, 7, 8, 10])
		ScaleType.LYDIAN:
			return PackedInt32Array([0, 2, 4, 6, 7, 9, 11])
		ScaleType.MIXOLYDIAN:
			return PackedInt32Array([0, 2, 4, 5, 7, 9, 10])
		ScaleType.LOCRIAN:
			return PackedInt32Array([0, 1, 3, 5, 6, 8, 10])
		ScaleType.WHOLE_TONE:
			return PackedInt32Array([0, 2, 4, 6, 8, 10])
		ScaleType.CHROMATIC:
			return PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
	return PackedInt32Array([0, 2, 4, 5, 7, 9, 11])

func get_desc(_data) -> String:
	var name := "%s(%s)" % [ScaleType.keys()[scale_type], _midi_name(root_midi)]
	return name

func _to_string() -> String:
	return "%s %s" % [_midi_name(root_midi), ScaleType.keys()[scale_type]]

## 音级(1 起) → MIDI 音高
func degree_to_midi(degree: int) -> int:
	var intervals := get_intervals(scale_type)
	var idx := (degree - 1) % intervals.size()
	var oct := (degree - 1) / intervals.size()
	return root_midi + intervals[idx] + 12 * oct

static func _midi_name(m: int) -> String:
	var names := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	return "%s%d" % [names[m % 12], m / 12 - 1]
