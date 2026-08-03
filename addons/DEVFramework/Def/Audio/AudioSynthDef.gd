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

## ——— 编辑器操作(Inspector 按钮, 点击即触发) ———
## 机制: 点击按钮 = 调用该属性存放的 Callable。用 getter 每次实时返回新 Callable,
## 避免脚本热重载后序列化属性变 nil 导致 "invalid callable" 报错。
## 播放/停止切换: 空闲时后台生成并按 bus/fx_chain 试听(BGM 自动循环), 生成中/播放中点击则停止
@export_tool_button("▶ 播放 ／ ■ 停止") var _preview_toggle:
	get:
		return func() -> void:
			if AudioTool.is_editor_preview_busy() or AudioTool.is_editor_preview_playing():
				AudioTool.stop_editor_preview()
			else:
				AudioTool.play_editor_preview(self)

## 弹窗选择保存路径, 异步烘焙当前定义为 WAV 文件并刷新资源面板
@export_tool_button("烘焙 WAV...") var _bake_wav:
	get:
		return func() -> void:
			_bake_to_wav()


## 烘焙到约定目录 res://Assets/Audio/Baked/<Def名>.wav(异步后台生成, 完成后刷新资源面板)
## 注意: 不用编辑器类硬引用(EditorFileDialog 等), 保证 Def 在游戏端也能安全编译
func _bake_to_wav() -> void:
	if not Engine.is_editor_hint():
		return
	DirAccess.make_dir_recursive_absolute("res://Assets/Audio/Baked")
	var path := "res://Assets/Audio/Baked/" + _default_bake_name()
	var err: Error = await AudioTool.bake_wav(self, path)
	LogTool.log("音频", "烘焙完成: ", path, " err=", err)


func _default_bake_name() -> String:
	var stem := resource_path.get_file().get_basename() if not resource_path.is_empty() else name
	return stem + ".wav"

func get_desc(_data) -> String:
	return "%s[%d声部/%d序列]" % [Category.keys()[category], voices.size(), patterns.size() + music.size()]

func _to_string() -> String:
	return "AudioSynth[%s, %dv]" % [Category.keys()[category], voices.size()]