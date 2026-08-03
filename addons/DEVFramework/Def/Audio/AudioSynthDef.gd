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
## 软削波驱动量(>0 启用，值越大越接近压缩/失真；离线母带，仅烘焙进 WAV)
@export_range(0.0, 4.0, 0.05) var soft_clip := 0.5

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

## ——— 编辑器预览(Inspector 按钮, 点击即触发) ———
## 机制: 点击按钮 = 调用该属性存放的 Callable。用 getter 每次实时返回新 Callable,
## 避免脚本热重载后序列化属性变 nil 导致 "invalid callable" 报错。
## 按当前设置后台生成并试听(自动路由到 bus/fx_chain, BGM 自动循环)
@export_tool_button("▶ 预览播放") var _preview_play:
	get:
		return func() -> void:
			AudioTool.play_editor_preview(self)
## 停止当前预览并取消未完成的生成
@export_tool_button("■ 停止预览") var _preview_stop:
	get:
		return func() -> void:
			AudioTool.stop_editor_preview()

func get_desc(_data) -> String:
	return "%s[%d声部/%d序列]" % [Category.keys()[category], voices.size(), patterns.size() + music.size()]

func _to_string() -> String:
	return "AudioSynth[%s, %dv]" % [Category.keys()[category], voices.size()]