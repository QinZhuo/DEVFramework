@tool
## 主合成器 — 把 AudioSynthDef 渲染成 AudioStreamWAV（离线/后台线程）
class_name AudioSynth

## 线程安全：仅返回纯数据字典（不创建 AudioStreamWAV）
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

	# 回声(共享单延迟线)
	if def.echo_enabled and def.echo_mix > 0.0:
		var delay_len := int(def.echo_delay_sec * sr)
		var dl: PackedFloat32Array = PackedFloat32Array()
		var dr: PackedFloat32Array = PackedFloat32Array()
		dl.resize(delay_len)
		dr.resize(delay_len)
		var di := 0
		for i in total:
			var sl := l[i]
			var sr_ := r[i]
			var el := dl[di]
			var er := dr[di]
			l[i] = sl + el * def.echo_mix
			r[i] = sr_ + er * def.echo_mix
			dl[di] = sl + el * def.echo_feedback
			dr[di] = sr_ + er * def.echo_feedback
			di += 1
			if di >= delay_len:
				di = 0

	# 淡出
	if def.fade_out > 0.0 and not def.loop:
		var fc := int(def.fade_out * sr)
		var start := maxi(0, total - fc)
		for i in range(start, total):
			var t := 1.0 - float(i - start) / maxi(1, fc)
			var minv := clampf(t, 0.0, 1.0)
			l[i] *= minv
			r[i] *= minv

	# 软削波 + 归一化（先统一到 ~1.0 电平再软削波，最后乘母带音量）
	var peak := 0.0
	for i in total:
		peak = maxf(peak, absf(l[i]))
		peak = maxf(peak, absf(r[i]))
	var norm := 0.97 / maxf(peak, 0.000001)
	var drive := def.soft_clip
	for i in total:
		l[i] = AudioDSP.soft_clip(l[i] * norm, drive) * def.master_volume
		r[i] = AudioDSP.soft_clip(r[i] * norm, drive) * def.master_volume

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

## 组装 AudioStreamWAV（须在主线程调用）
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

## 同步渲染（主线程，短音效合适）
static func render(def: AudioSynthDef) -> AudioStreamWAV:
	return build_stream(render_data(def))