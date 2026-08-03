@tool
## 程序化音频工具 — 生成/预览/保存/播放音频 + Godot 内置总线效果链管理
## 通用音频功能统一集中于此:
##   生成(AudioStreamWAV) / 播放(总线路由) / 保存(标准 WAV 写出) / 查询
##   总线管理(ensure_bus / setup_*_buses) — 混响/延迟/压缩/限幅/失真/EQ 全部用 Godot 内置 AudioEffect
class_name AudioTool

## 标准总线布局资源保存路径(供项目设置引用)
const LAYOUT_PATH := "res://Assets/Audio/AudioBusLayout.tres"
const LAYOUT_SETTING := "audio/buses/default_bus_layout"
## 示例定义目录(AudioTool.example_def / play_example)
const EXAMPLES_DIR := "res://Assets/Def/Audio/Examples/"

## 支持的效果名(用于 AudioSynthDef.fx_chain)
static var fx_names := [
	"reverb", "reverb_hall", "delay", "distortion",
	"limiter", "compressor", "eq_lowpass", "eq_highpass", "eq_bandpass", "spectrum",
]

## ======= 合成内核(原 AudioDSP 合并至此) =======

## 波形枚举（与 AudioOscillatorDef.Wave 一致）
enum Wave {SINE, SQUARE, SAW, TRIANGLE, PULSE, NOISE}

## PolyBLEP 抗锯齿修正——消除方波/锯齿/三角波的高频混叠，让音色"干净"
static func poly_blep(t: float, dt: float) -> float:
	if t < dt:
		t /= dt
		return t + t - t * t - 1.0
	elif t > 1.0 - dt:
		t = (t - 1.0) / dt
		return t * t + t + t + 1.0
	return 0.0

static func _wrap(p: float) -> float:
	return p - floorf(p)

## 生成一帧波形。phase 为 0~1 相位，dt 为每采样相位步进，duty 为 PULSE 占空比
static func osc(wave: int, phase: float, dt: float, duty := 0.5, rng: RandomNumberGenerator = null) -> float:
	match wave:
		Wave.SINE:
			return sin(phase * TAU)
		Wave.SQUARE:
			var s := 1.0 if phase < 0.5 else -1.0
			s += poly_blep(phase, dt) - poly_blep(_wrap(phase + 0.5), dt)
			return s
		Wave.SAW:
			var s := 2.0 * phase - 1.0
			s -= poly_blep(phase, dt)
			return s
		Wave.TRIANGLE:
			var s := 2.0 * phase - 1.0
			s -= poly_blep(phase, dt)
			var p2 := _wrap(phase + 0.5)
			var s2 := 2.0 * p2 - 1.0
			s2 -= poly_blep(p2, dt)
			return (s - s2) * 0.5
		Wave.PULSE:
			var s := 1.0 if phase < duty else -1.0
			s += poly_blep(phase, dt) - poly_blep(_wrap(phase - duty + 1.0), dt)
			return s
		Wave.NOISE:
			if rng:
				return rng.randf_range(-1.0, 1.0)
			return randf_range(-1.0, 1.0)
	return 0.0

## 非线性软削波(tanh)——温和过载，防止爆音并带来温暖感
static func soft_clip(x: float, drive: float) -> float:
	if drive <= 0.0001:
		return x
	return tanh(x * drive)

## 状态变量滤波器(SVF)，支持低通/带通/高通，带截止频率调制
class SVFilter:
	var sample_rate := 44100.0
	var mode := 0
	var cutoff := 8000.0
	var resonance := 0.3
	var _low := 0.0
	var _band := 0.0

	func _init(sr: float = 44100.0, c: float = 8000.0, r: float = 0.3, m: int = 0) -> void:
		sample_rate = sr
		cutoff = c
		resonance = r
		mode = m

	func reset() -> void:
		_low = 0.0
		_band = 0.0

	func process(x: float) -> float:
		var f := 2.0 * sin(PI * clampf(cutoff, 20.0, sample_rate * 0.45) / sample_rate)
		var q := 2.0 * (1.0 - clampf(resonance, 0.0, 1.0)) + 0.5
		_low += f * _band
		var high := x - _low - q * _band
		_band = f * high + _band
		match mode:
			1:
				return _band
			2:
				return high
		return _low

## 指数衰减 ADSR 包络（逐采样，支持曲线）
class ADSR:
	var sample_rate := 44100.0
	var attack := 0.005
	var decay := 0.1
	var sustain := 0.7
	var release := 0.2
	var curve := 0.0

	var _phase := -1
	var _timer := 0.0
	var _start_level := 0.0
	var _level := 0.0

	func _init(sr: float = 44100.0) -> void:
		sample_rate = sr

	func reset() -> void:
		_phase = -1
		_level = 0.0

	func note_on() -> void:
		_phase = 0
		_timer = 0.0
		_start_level = maxf(_level, 0.0)

	func note_off() -> void:
		if _phase >= 0 and _phase <= 2:
			_phase = 3
			_timer = 0.0
			_start_level = _level

	func is_done() -> bool:
		return _phase == -1

	func get_level() -> float:
		return _level

	func process() -> float:
		var dt := 1.0 / sample_rate
		_timer += dt
		match _phase:
			0:
				var t0 := 1.0 if attack <= 0.0 else _timer / attack
				_level = _curve_segment(_start_level, 1.0, clampf(t0, 0.0, 1.0))
				if _timer >= attack:
					_phase = 1
					_timer = 0.0
			1:
				var t1 := 1.0 if decay <= 0.0 else _timer / decay
				_level = _curve_segment(1.0, sustain, clampf(t1, 0.0, 1.0))
				if _timer >= decay:
					_phase = 2
			2:
				_level = sustain
			3:
				var t3 := 1.0 if release <= 0.0 else _timer / release
				_level = _curve_segment(_start_level, 0.0, clampf(t3, 0.0, 1.0))
				if _timer >= release:
					_phase = -1
					_level = 0.0
		return _level

	func _curve_segment(a: float, b: float, t: float) -> float:
		if absf(curve) < 0.001:
			return lerpf(a, b, t)
		if curve > 0.0:
			return lerpf(a, b, pow(t, 1.0 + curve))
		return lerpf(a, b, pow(t, 1.0 / (1.0 - curve)))

## MIDI 音高 → 频率
static func midi_to_freq(m: int) -> float:
	return 440.0 * pow(2.0, (m - 69.0) / 12.0)

## ======= 合成渲染(原 AudioSynth 合并至此) =======

## 主渲染器: 把 AudioSynthDef 展开成 int16 交错立体声数据
## 线程安全: 仅返回纯数据字典(不创建 AudioStreamWAV), 供后台线程使用
static func render_data(def: AudioSynthDef) -> Dictionary:
	var sr := int(def.sample_rate)
	var events: Array = AudioSequence.expand(def)

	var total := int(def.duration * sr) if def.duration > 0.0 else 0
	for e in events:
		total = maxi(total, int(e.start) + int(e.duration))
	# 缓冲一段包络释放尾音
	total += int(0.2 * sr)
	if total <= 0:
		return {"ok": false, "reason": "没有可渲染的音符或时长"}

	var l := PackedFloat32Array()
	var r := PackedFloat32Array()
	l.resize(total)
	r.resize(total)
	l.fill(0.0)
	r.fill(0.0)

	var per_voice: Array = []
	for i in def.voices.size():
		per_voice.append([])
	for e in events:
		var vi := int(e.voice_index)
		if vi >= 0 and vi < per_voice.size():
			per_voice[vi].append(e)

	for vi in def.voices.size():
		var vd: AudioVoiceDef = def.voices[vi]
		var voice := AudioVoice.new(vd, sr)
		voice.events = per_voice[vi]
		var mono := voice.render_to_array(total)
		var pan := clampf(vd.pan, -1.0, 1.0)
		var gl := cos((pan + 1.0) * PI / 4.0) * vd.volume
		var gr := sin((pan + 1.0) * PI / 4.0) * vd.volume
		for i in total:
			l[i] += mono[i] * gl
			r[i] += mono[i] * gr

	# 回声/延迟/混响等后期效果不自研, 由 Godot 内置 AudioEffect 在播放总线上提供(AudioSynthDef.bus + fx_chain)

	# 淡出
	if def.fade_out > 0.0 and not def.loop:
		var fc := int(def.fade_out * sr)
		var start := maxi(0, total - fc)
		for i in range(start, total):
			var t := 1.0 - float(i - start) / maxi(1, fc)
			var minv := clampf(t, 0.0, 1.0)
			l[i] *= minv
			r[i] *= minv

	# 软削波 + 归一化(先统一到 ~1.0 电平再软削波, 最后乘母带音量)
	var peak := 0.0
	for i in total:
		peak = maxf(peak, absf(l[i]))
		peak = maxf(peak, absf(r[i]))
	var norm := 0.97 / maxf(peak, 0.000001)
	var drive := def.soft_clip
	for i in total:
		l[i] = soft_clip(l[i] * norm, drive) * def.master_volume
		r[i] = soft_clip(r[i] * norm, drive) * def.master_volume

	# 转 int16 交错立体声
	var bytes := PackedByteArray()
	bytes.resize(total * 2 * 2)
	for i in total:
		_write_i16(bytes, i * 4, int(clampf(l[i], -1.0, 1.0) * 32767.0))
		_write_i16(bytes, i * 4 + 2, int(clampf(r[i], -1.0, 1.0) * 32767.0))

	return {
		"sample_rate": sr,
		"frames": total,
		"data": bytes,
		"loop": def.loop,
	}

static func _write_i16(bytes: PackedByteArray, off: int, v: int) -> void:
	bytes[off] = v & 0xFF
	bytes[off + 1] = (v >> 8) & 0xFF

## 组条 AudioStreamWAV(须在主线程调用)
static func build_stream(data: Dictionary) -> AudioStreamWAV:
	if data.is_empty() or data.get("err", false):
		return null
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = data.sample_rate
	stream.data = data.data
	if data.get("loop", false):
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = data.frames
	return stream

## 同步渲染(主线程, 短音效合适)
static func render(def: AudioSynthDef) -> AudioStreamWAV:
	return build_stream(render_data(def))

## ============ 生成 ============

## 同步生成音频流(声成即渲染; 短音效建议用, BGM 建议 generate_async)
static func generate(def: AudioSynthDef) -> AudioStreamWAV:
	return render(def)

## 后台线程生成(不阻塞主线程), await 返回 AudioStreamWAV 或 null
static func generate_async(def: AudioSynthDef) -> AudioStreamWAV:
	var t := LogTool.timer("音频", str("后台生成: ", def))
	var data: Dictionary = await AsyncTool.thread_call(func() -> Dictionary:
		return render_data(def)
	)
	t.stop()
	if data.is_empty() or data.get("err", false):
		LogTool.error("音频", "生成失败: ", def)
		return null
	return build_stream(data)

## ============ 播放 ============

## 生成并立即播放(自动挂到场景树, 播放结束自动释放; 按定义的总线与效果链走 Godot 内置效果)
static func play(def: AudioSynthDef, volume_db := 0.0) -> AudioStreamPlayer:
	var stream := generate(def)
	if stream == null:
		return null
	return play_stream(stream, volume_db, def.bus if def.bus else "Master", def.fx_chain)

## 播放已有音频流(自动释放); bus 为空用 Master, fx 非空时自动建 "FX_<bus>" 效果总线
static func play_stream(stream: AudioStream, volume_db := 0.0, bus := "Master", fx: PackedStringArray = []) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	player.bus = resolve_bus(bus, fx)
	var root := Engine.get_main_loop() as SceneTree
	if root and root.root:
		root.root.add_child(player)
		player.play()
		player.finished.connect(player.queue_free)
	return player

## 实时无限循环播放 BGM(基于 Godot AudioStreamGenerator, 不占内存): 一行启动, 返回播放器可自由控制/停止
static func play_loop(def: AudioSynthDef) -> AudioLivePlayer:
	var player := AudioLivePlayer.new()
	var root := Engine.get_main_loop() as SceneTree
	if root and root.root:
		root.root.add_child(player)
	player.setup(def)
	player.play()
	return player

## ============ 编辑器预览(Inspector 按钮使用) ============

## 存储预览状态: 每次调用都生成新 token, 后台生成完成后对比发现 token 变化则丢弃结果(实现取消)
static var _preview_player: AudioStreamPlayer
static var _preview_busy := false
static var _preview_token := 0

## 在编辑器中试听 Def: 先停止旧的, 后台线程生成, 完成后按定义的 bus/fx_chain 播放(loop 的 BGM 自动循环)
## on_ready(result: bool) 可选, 生成播放成功后回调
static func play_editor_preview(def: AudioSynthDef, on_ready: Callable = Callable()) -> void:
	# 先停止旧的(使其 token 失效), 再自增领取新 token — 防止把自己的 token 顶掉
	stop_editor_preview()
	_preview_token += 1
	var token := _preview_token
	_preview_busy = true
	var stream: AudioStreamWAV = await generate_async(def)
	if token != _preview_token:
		return
	_preview_busy = false
	if stream == null:
		if on_ready.is_valid():
			on_ready.call(false)
		return
	_preview_player = play_stream(stream, 0.0, def.bus if def.bus else "Master", def.fx_chain)
	if on_ready.is_valid():
		on_ready.call(true)

## 停止当前编辑器预览(同时使未完成的异步生成结果失效)
static func stop_editor_preview() -> void:
	_preview_token += 1
	_preview_busy = false
	if is_instance_valid(_preview_player):
		_preview_player.stop()
		_preview_player.queue_free()
	_preview_player = null

## 是否在后台生成中
static func is_editor_preview_busy() -> bool:
	return _preview_busy

## 是否正在播放预览中
static func is_editor_preview_playing() -> bool:
	return is_instance_valid(_preview_player) and _preview_player.playing

## 烘焙 Def 为 WAV 文件(异步后台生成 + 标准立体声 WAV 写出): 编辑器按钮一键导出成品音频
## 返回 Error; 编辑器环境下保存后自动刷新文件系统
static func bake_wav(def: AudioSynthDef, path: String) -> Error:
	stop_editor_preview()
	var stream: AudioStreamWAV = await generate_async(def)
	if stream == null:
		return ERR_CANT_CREATE
	if not path.ends_with(".wav"):
		path += ".wav"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	var err := save_wav(stream, path)
	if err == OK:
		LogTool.log("音频", "已烘焙为 WAV: ", path)
		# 编辑器下刷新文件系统使其出现在资源面板(用单例方式取 EditorInterface, 避免编辑器类硬引用)
		if Engine.is_editor_hint():
			var iface := Engine.get_singleton("EditorInterface")
			if iface:
				var fs = iface.get("resource_filesystem")
				if fs:
					fs.call("scan")
	else:
		LogTool.error("音频", "烘焙失败: ", path, " err=", err)
	return err

## ============ 示例快捷访问 ============

## 按名称加载示例定义(DevAudioExamples 生成, 位于 Assets/Def/Audio/Examples/), 不存在返回 null
static func example_def(name: String) -> AudioSynthDef:
	var path := EXAMPLES_DIR + name + ".tres"
	if not ResourceLoader.exists(path):
		LogTool.warn("音频", "示例定义不存在: ", name, " (可用 list_examples 查看)")
		return null
	return load(path)

## 列出全部示例定义名
static func list_examples() -> Array:
	var out: Array = []
	var dir := DirAccess.open(EXAMPLES_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while not f.is_empty():
		if f.ends_with(".tres"):
			out.append(f.trim_suffix(".tres"))
		f = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out

## 一行播放示例音效(如 AudioTool.play_example("SFX_Laser"))
static func play_example(name: String, volume_db := 0.0) -> AudioStreamPlayer:
	var def := example_def(name)
	if def == null:
		return null
	return play(def, volume_db)

## ============ 保存 ============

## 保存为 WAV 文件。
## 注意: 4.7.1 内置 AudioStreamWAV.save_to_wav 会把 16bit 立体声写成 mono 头(数据仍交错),
## 导致 Godot 重新导入后声道/时长错乱, 故这里手写标准 44 字节 PCM 头(立体声/16bit)
static func save_wav(stream: AudioStreamWAV, path: String) -> Error:
	if stream == null or stream.data.is_empty():
		return ERR_INVALID_DATA
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	var data := stream.data
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + data.size())
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)          # fmt 块长度
	f.store_16(1)           # PCM 编码
	f.store_16(2)           # 声道数: 立体声
	f.store_32(stream.mix_rate)
	f.store_32(stream.mix_rate * 4)  # byte_rate = rate * channels * 2
	f.store_16(4)           # block_align = channels * 2
	f.store_16(16)          # 位深
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(data.size())
	f.store_buffer(data)
	f.close()
	return OK

## 保存为 Godot 音频资源(.tres/.res)，供编辑器直接拖入 AudioStreamPlayer
static func save_resource(stream: AudioStream, path: String) -> Error:
	if stream == null:
		return ERR_INVALID_DATA
	return ResourceSaver.save(stream, path)

## 从定义直接保存 WAV（生成 + 写盘一步到位）
static func generate_and_save(def: AudioSynthDef, wav_path: String) -> Error:
	var stream := generate(def)
	if stream == null:
		return ERR_CANT_CREATE
	return save_wav(stream, wav_path)

## ============ 流信息 ============

## 查询音频流信息(时长/采样率/声道/循环), 便于验证生成结果
## 注意: 16bit 数据可直算帧数; 从磁盘导入的 wav 可能是 QOA 压缩(FORMAT_QOA), 无帧数信息
static func get_stream_info(stream: AudioStreamWAV) -> Dictionary:
	if stream == null or stream.data.is_empty():
		return {}
	var info := {
		"mix_rate": stream.mix_rate,
		"channels": 2,
		"format": stream.format,
		"loop": stream.loop_mode != AudioStreamWAV.LOOP_DISABLED,
		"loop_begin": stream.loop_begin,
		"loop_end": stream.loop_end,
	}
	if stream.format == AudioStreamWAV.FORMAT_16_BITS:
		var frame_count := stream.data.size() / 4
		info["frames"] = frame_count
		info["seconds"] = float(frame_count) / stream.mix_rate
	return info

## ============ 总线管理(整合 Godot AudioServer + AudioEffect) ============

## 按名称创建 Godot 内置效果(AudioEffect), 未知名称返回 null
## 注意: 属性名以本项目 Godot 4.7.1(steam) 实际 API 为准
static func create_fx(name: String) -> AudioEffect:
	match name:
		"reverb":
			var fx := AudioEffectReverb.new()
			fx.room_size = 0.55
			fx.damping = 0.35
			fx.dry = 0.85
			fx.wet = 0.3
			fx.spread = 0.6
			return fx
		"reverb_hall":
			var fx := AudioEffectReverb.new()
			fx.predelay_msec = 20.0
			fx.room_size = 0.95
			fx.damping = 0.45
			fx.dry = 0.6
			fx.wet = 0.5
			fx.spread = 0.9
			return fx
		"delay":
			var fx := AudioEffectDelay.new()
			fx.dry = 1.0
			fx.tap1_active = true
			fx.tap1_delay_ms = 250.0
			fx.tap1_level_db = -10.0
			fx.tap1_pan = -0.3
			fx.feedback_active = true
			fx.feedback_delay_ms = 250.0
			fx.feedback_level_db = -8.0
			fx.feedback_lowpass = 4500.0
			return fx
		"distortion":
			var fx := AudioEffectDistortion.new()
			fx.mode = AudioEffectDistortion.Mode.MODE_CLIP
			fx.pre_gain = 6.0
			fx.drive = 0.35
			fx.post_gain = -4.0
			return fx
		"limiter":
			var fx := AudioEffectLimiter.new()
			fx.threshold_db = -3.0
			fx.ceiling_db = -1.0
			return fx
		"compressor":
			var fx := AudioEffectCompressor.new()
			fx.threshold = -18.0
			fx.ratio = 3.0
			fx.gain = 4.0
			fx.attack_us = 5000
			fx.release_ms = 120.0
			return fx
		"eq_lowpass":
			var fx := AudioEffectLowPassFilter.new()
			fx.cutoff_hz = 4500.0
			fx.resonance = 0.6
			return fx
		"eq_highpass":
			var fx := AudioEffectHighPassFilter.new()
			fx.cutoff_hz = 160.0
			fx.resonance = 0.5
			return fx
		"eq_bandpass":
			var fx := AudioEffectBandPassFilter.new()
			fx.cutoff_hz = 2200.0
			fx.resonance = 1.0
			return fx
		"spectrum":
			return AudioEffectSpectrumAnalyzer.new()
	return null

## 确保总线存在(幂等), 并按要求挂载效果链; 返回总线索引
static func ensure_bus(name: String, fx: PackedStringArray = []) -> int:
	var idx := AudioServer.get_bus_index(name)
	if idx != -1:
		return idx
	idx = AudioServer.bus_count
	AudioServer.add_bus()
	AudioServer.set_bus_name(idx, name)
	for fname in fx:
		var effect := create_fx(fname)
		if effect:
			AudioServer.add_bus_effect(idx, effect)
		else:
			LogTool.warn("音频", "未知效果名, 已跳过: ", fname)
	LogTool.log("音频", "已创建总线: ", name, " 效果=", fx)
	return idx

## 根据需要计算实际播放总线名: 带效果链时自动建 "FX_<bus>" 效果总线
static func resolve_bus(bus: String, fx: PackedStringArray) -> String:
	var name := bus if not bus.is_empty() else "Master"
	if not fx.is_empty():
		name = "FX_" + name
	ensure_bus(name, fx)
	return name

## 一键生成标准总线布局(Master 限幅 / SFX 轻混响+限幅 / BGM 大厅混响+压缩 / UI):
## 1) 立即应用到 AudioServer; 2) 保存为 AudioBusLayout.tres; 3) 写入项目设置
static func setup_audio_buses(apply := true) -> Dictionary:
	var layout := {
		"Master": ["limiter"],
		"SFX": ["reverb", "limiter"],
		"BGM": ["reverb_hall", "compressor"],
		"UI": [],
	}
	if apply:
		# 清空现有总线(保留 0 号 Master)再重建标准布局
		AudioServer.set_bus_count(1)
		while AudioServer.get_bus_effect_count(0) > 0:
			AudioServer.remove_bus_effect(0, 0)
		for name in layout.keys():
			if name != "Master":
				ensure_bus(name, layout[name])
			else:
				for fname in layout[name]:
					var effect := create_fx(fname)
					if effect:
						AudioServer.add_bus_effect(0, effect)
	DirAccess.make_dir_recursive_absolute("res://Assets/Audio")
	var bus_layout := AudioServer.generate_bus_layout()
	var err := ResourceSaver.save(bus_layout, LAYOUT_PATH)
	if err != OK:
		LogTool.error("音频", "保存总线布局失败: ", err)
		return {"ok": false, "error": err}
	ProjectSettings.set_setting(LAYOUT_SETTING, LAYOUT_PATH)
	ProjectSettings.save()
	var buses := {}
	for name in layout.keys():
		buses[name] = AudioServer.get_bus_index(name)
	LogTool.log("音频", "标准总线布局已就绪: ", buses)
	return {"ok": true, "buses": buses, "layout_path": LAYOUT_PATH}