## 程序化音频风格画廊 — 展示程序化生成能覆盖的音乐风格与能力边界
## 每个 BGM 按钮对应一种风格, 点击播放并在 InfoLabel 展示"风格构成 + 用到的能力"
## 播放全部通过 AudioTool 一行 API 完成
extends Control

var _bgm: AudioStreamPlayer
var _info: Label

## 风格画廊: 按钮名 → [Def 名, 风格说明(风格名/音色构成/用到的能力)]
var _styles := {
	"BtnBgmAdventure": ["BGM_Loop_Adventure",
		"复古冒险 BGM\n音色: 方块波主奏 + 方波贝斯 + 完整鼓组\n能力: 减法合成 + 自动编曲(旋律/和弦/贝斯/鼓)"],
	"BtnBgmAmbient": ["BGM_Loop_Ambient",
		"环境氛围 BGM\n音色: 长音 pad + 低频 drone + 琶音\n能力: 减法合成 + 琶音编曲 + 大厅混响"],
	"BtnBgmChiptune": ["BGM_Chiptune",
		"8-bit 复古(Chiptune)\n音色: 方块波主奏 + 三角波琶音 + 16 分镲\n能力: 减法合成 + 快速琶音 + 鼓模式"],
	"BtnBgmRock": ["BGM_Rock",
		"摇滚(Rock)\n音色: 失真吉他 power chord + 重军鼓\n能力: 失真效果链 + 鼓模式 + 挂留和弦"],
	"BtnBgmHouse": ["BGM_Loop_House",
		"House 舞曲\n音色: FM 电钢 + 四踩鼓 + 反拍镲\n能力: 鼓模式预设 + FM 频率调制"],
	"BtnBgmTrap": ["BGM_Trap",
		"陷阱(Trap)\n音色: 重低音(LFO 抽吸) + FM 钟 + 三连鼓\n能力: 鼓模式(三连/切分) + FM + LFO 音量"],
	"BtnBgmJazz": ["BGM_Loop_Jazz",
		"爵士(Jazz)\n音色: FM 电钢 7/9 和弦 + 摇摆鼓\n能力: 和声深度(9 和弦/调式交换) + 鼓模式摇摆"],
	"BtnBgmCinematic": ["BGM_Cinematic",
		"电影管弦(Cinematic)\n音色: 失谐弦乐 pad + 低音 drone + 定音鼓\n能力: 振荡器叠加 + 7 和弦 + 慢速长音包络"],
	"BtnBgmWorld": ["BGM_World",
		"世界/拨弦(World)\n音色: Karplus 竖琴琶音 + 笛音旋律\n能力: 物理建模拨弦 + 五声音阶 + 开镲点缀"],
	"BtnBgmShowcase": ["BGM_Showcase",
		"综合编曲(Showcase)\n音色: FM 电钢+拨弦+Acid 贝斯+FM 主奏\n能力: 段落结构 + LFO 扫频 + 鼓切换 + 转调(全能力)"],
}

var _sfx := {
	"BtnLaser": "SFX_Laser",
	"BtnExplosion": "SFX_Explosion",
	"BtnCoin": "SFX_Coin",
	"BtnHit": "SFX_Hit",
}

func _ready() -> void:
	_bind_buttons()
	_info = find_child("InfoLabel", true, false) as Label

func _bind_buttons() -> void:
	for btn_name in _styles.keys():
		var btn := find_child(btn_name, true, false) as Button
		if btn:
			btn.pressed.connect(_on_style.bind(btn_name))
	for btn_name in _sfx.keys():
		var btn := find_child(btn_name, true, false) as Button
		if btn:
			btn.pressed.connect(_on_sfx.bind(btn_name))
	var stop := find_child("BtnStopBgm", true, false) as Button
	if stop:
		stop.pressed.connect(_stop_bgm)

func _on_style(btn_name: String) -> void:
	var entry: Array = _styles[btn_name]
	_play_bgm(entry[0], entry[1])

func _on_sfx(name: String) -> void:
	AudioTool.play_example(name)

func _play_bgm(name: String, style_info: String) -> void:
	_stop_bgm()
	var def := AudioTool.example_def(name)
	if def == null:
		return
	if _info:
		_info.text = "生成中: %s" % style_info.split("\n")[0]
	_bgm = AudioTool.play_loop(def, func(p):
		var st := p.stream as AudioStreamWAV
		if _info and st:
			var channel := "立体声" if st.stereo else "单声道"
			var loop := "循环" if st.loop_mode != AudioStreamWAV.LOOP_DISABLED else "单次"
			_info.text = "%s\n\n%s | %.1fs | %s | %s | %dHz" % [style_info, name, st.get_length(), channel, loop, st.mix_rate]
	)

func _stop_bgm() -> void:
	if _bgm:
		_bgm.stop()
		_bgm.queue_free()
		_bgm = null
	if _info:
		_info.text = ""
