@tool
## 程序化音频定义 — 组合一组音色 + 一组序列(显式/自动编曲)，一键渲染成 AudioStreamWAV
class_name AudioSynthDef extends Def

enum Category {SFX, BGM, AMBIENT, LOOP}

@export var category: Category = Category.SFX
@export_range(8000, 48000, 1000) var sample_rate := 44100
## 时长(秒)；0 表示由序列/编曲自动推算
@export_range(0.0, 600.0, 0.1) var duration := 0.0
@export var voices: Array[AudioVoiceDef] = []
@export var patterns: Array[AudioPatternDef] = []
@export var music: Array[AudioMusicDef] = []

## ——— 母带与效果 ———
@export_range(0.0, 1.0, 0.001) var master_volume := 0.9
## 软削波驱动量(>0 启用，值越大越接近压缩/失真)
@export_range(0.0, 4.0, 0.05) var soft_clip := 0.5
## 离线回声(烘焙进 WAV)。轻量使用; 更自然的混响/延迟建议走 fx_chain(运行时 Godot 内置效果)
@export var echo_enabled := false
@export_range(0.0, 1.0, 0.001) var echo_feedback := 0.3
@export_range(0.0, 1.0, 0.001) var echo_mix := 0.2
@export_range(0.0, 2.0, 0.01) var echo_delay_sec := 0.25

## ——— 播放总线(整合 Godot AudioServer) ———
## 播放时自动路由到该总线; 标准布局由 AudioTool.setup_audio_buses() 一键创建
@export var bus := "Master"
## 运行时总线效果链(由 Godot 内置 AudioEffect 提供, 播放时生效, 不写入离线 WAV):
## 可选值: reverb / delay / distortion / limiter / compressor / eq_lowpass / eq_highpass / spectrum
@export var fx_chain: PackedStringArray = []

## ——— 循环 ———
@export var loop := false
## 尾部淡出(秒)，用于非循环片段平滑收尾
@export_range(0.0, 5.0, 0.05) var fade_out := 0.0

func get_desc(_data) -> String:
	return "%s[%d声部/%d序列]" % [Category.keys()[category], voices.size(), patterns.size() + music.size()]

func _to_string() -> String:
	return "AudioSynth[%s, %dv]" % [Category.keys()[category], voices.size()]