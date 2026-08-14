## 程序化音频 Demo — 展示生成的音效与循环 BGM
## 场景内已排布按钮，脚本按节点名称绑定触发逻辑（界面由场景搭建）
## 播放全部通过 AudioTool 一行 API 完成
extends Control

var _bgm: AudioStreamPlayer
var _info: Label

func _ready() -> void:
	_bind_buttons()
	_info = find_child("InfoLabel", true, false) as Label

func _bind_buttons() -> void:
	var targets := {
		"BtnLaser": "SFX_Laser",
		"BtnExplosion": "SFX_Explosion",
		"BtnCoin": "SFX_Coin",
		"BtnHit": "SFX_Hit",
		"BtnBgmAdventure": "BGM_Loop_Adventure",
		"BtnBgmAmbient": "BGM_Loop_Ambient",
		"BtnBgmHouse": "BGM_Loop_House",
		"BtnBgmJazz": "BGM_Loop_Jazz",
		"BtnBgmShowcase": "BGM_Showcase",
		"BtnStopBgm": "",
	}
	for btn_name in targets.keys():
		var btn := find_child(btn_name, true, false) as Button
		if btn:
			btn.pressed.connect(_on_sound.bind(targets[btn_name]))

func _on_sound(name: String) -> void:
	if name == "":
		_stop_bgm()
	elif name.begins_with("BGM"):
		_play_bgm(name)
	else:
		AudioTool.play_example(name)

func _play_bgm(name: String) -> void:
	_stop_bgm()
	var def := AudioTool.example_def(name)
	if def == null:
		return
	if _info:
		_info.text = "BGM: %s（后台生成中…）" % name
	_bgm = AudioTool.play_loop(def, func(p):
		var st := p.stream as AudioStreamWAV
		if _info and st:
			var channel := "立体声" if st.stereo else "单声道"
			var loop := "循环" if st.loop_mode != AudioStreamWAV.LOOP_DISABLED else "单次"
			_info.text = "BGM: %s  |  %.1fs  |  %s  |  %s  |  %dHz" % [name, st.get_length(), channel, loop, st.mix_rate]
	)

func _stop_bgm() -> void:
	if _bgm:
		_bgm.stop()
		_bgm.queue_free()
		_bgm = null
	if _info:
		_info.text = ""
