@tool
## 程序化音频工具 — 一键生成/预览/保存 AudioStreamWAV，支持后台线程生成
class_name AudioTool

## 同步生成音频流（阻塞；短音效建议用，BGM 建议 generate_async）
static func generate(def: AudioSynthDef) -> AudioStreamWAV:
	return AudioSynth.render(def)

## 后台线程生成（不阻塞主线程），await 返回 AudioStreamWAV 或 null
static func generate_async(def: AudioSynthDef) -> AudioStreamWAV:
	var t := LogTool.timer("音频", str("后台生成: ", def))
	var data: Dictionary = await AsyncTool.thread_call(func() -> Dictionary:
		return AudioSynth.render_data(def)
	)
	t.stop()
	if data.is_empty() or data.get("err", false):
		LogTool.error("音频", "生成失败: ", def)
		return null
	return AudioSynth.build_stream(data)

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
	player.bus = AudioBusManager.resolve_bus(bus, fx)
	var root := Engine.get_main_loop() as SceneTree
	if root and root.root:
		root.root.add_child(player)
		player.play()
		player.finished.connect(player.queue_free)
	return player

## 一键生成标准音频总线布局(Master/SFX/BGM/UI + Godot 内置效果), 并写入项目设置
static func setup_audio_buses(apply := true) -> Dictionary:
	return AudioBusManager.setup_standard_layout(apply)

## 保存为 WAV 文件（PCM 16bit 立体声）
static func save_wav(stream: AudioStreamWAV, path: String) -> Error:
	if stream == null or stream.data.is_empty():
		return ERR_INVALID_DATA
	var channels := 2
	var bits := 16
	var byte_rate := stream.mix_rate * channels * bits / 8
	var data_size := stream.data.size()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	_write_str(f, "RIFF")
	_write_u32(f, 36 + data_size)
	_write_str(f, "WAVE")
	_write_str(f, "fmt ")
	_write_u32(f, 16)
	_write_u16(f, 1)                      # PCM
	_write_u16(f, channels)
	_write_u32(f, stream.mix_rate)
	_write_u32(f, byte_rate)
	_write_u16(f, channels * bits / 8)
	_write_u16(f, bits)
	_write_str(f, "data")
	_write_u32(f, data_size)
	f.store_buffer(stream.data)
	f.close()
	return OK

static func _write_str(f: FileAccess, s: String) -> void:
	f.store_buffer(s.to_ascii_buffer())

static func _write_u16(f: FileAccess, v: int) -> void:
	f.store_buffer(PackedByteArray([v & 0xFF, (v >> 8) & 0xFF]))

static func _write_u32(f: FileAccess, v: int) -> void:
	f.store_buffer(PackedByteArray([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]))

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

## 查询音频流信息(时长/采样率/声道/循环), 便于验证生成结果
static func get_stream_info(stream: AudioStreamWAV) -> Dictionary:
	if stream == null or stream.data.is_empty():
		return {}
	var channels := 2
	var frame_count := stream.data.size() / (channels * 2)
	return {
		"mix_rate": stream.mix_rate,
		"channels": channels,
		"frames": frame_count,
		"seconds": float(frame_count) / stream.mix_rate,
		"loop": stream.loop_mode != AudioStreamWAV.LOOP_DISABLED,
		"loop_begin": stream.loop_begin,
		"loop_end": stream.loop_end,
	}