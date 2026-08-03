@tool
## 音频 DSP 静态工具 — PolyBLEP 抗锯齿振荡器、SVF 滤波器、ADSR 包络、软削波
class_name AudioDSP

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