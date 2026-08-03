@tool
## 音色定义 — 一个可演奏的发声器（音调类或打击乐类），可多层振荡器叠加 + 滤波 + 颤音 + 滑音
class_name AudioVoiceDef extends Def

enum Kind {TONE, DRUM}
enum DrumType {KICK, SNARE, HAT_OPEN, HAT_CLOSED, TOM, CLAP}

@export var kind: Kind = Kind.TONE

## ——— 音调类参数 ———
@export var oscillators: Array[AudioOscillatorDef] = []
## 白噪声混合量(0~1)，可叠加在振荡器上
@export_range(0.0, 1.0, 0.001) var noise_amount := 0.0
@export var envelope: AudioEnvelopeDef = AudioEnvelopeDef.new()
@export var filter: AudioFilterDef = AudioFilterDef.new()

## ——— 公共参数 ———
@export_range(0.0, 1.0, 0.001) var volume := 0.8
@export_range(-1.0, 1.0, 0.01) var pan := 0.0
## 颤音速率(Hz)
@export_range(0.0, 20.0, 0.01) var vibrato_rate := 5.0
## 颤音深度(半音)
@export_range(0.0, 1.0, 0.001) var vibrato_depth := 0.0
## 滑音时间(秒)，0 表示无滑音
@export_range(0.0, 2.0, 0.001) var glide := 0.0

## ——— 打击乐类参数 ———
@export var drum_type: DrumType = DrumType.KICK
## 鼓基础频率(Hz)，KICK/TOM 用
@export_range(20.0, 2000.0, 1.0) var drum_freq := 90.0
## 鼓体声(低频)占比
@export_range(0.0, 1.0, 0.001) var drum_tone := 0.6
## 鼓噪声占比
@export_range(0.0, 1.0, 0.001) var drum_noise := 0.4
## 鼓时长(秒)
@export_range(0.01, 2.0, 0.01) var drum_length := 0.3

func get_desc(_data) -> String:
	if kind == Kind.DRUM:
		return "鼓-%s" % DrumType.keys()[drum_type]
	var o := "osc=%d" % oscillators.size() if not oscillators.is_empty() else "osc=0"
	return "音调-%s v=%.2f" % [o, volume]

func _to_string() -> String:
	if kind == Kind.DRUM:
		return "Drum[%s]" % DrumType.keys()[drum_type]
	return "Voice[%s]" % ("+".join(oscillators.map(func(o): return str(o))))
