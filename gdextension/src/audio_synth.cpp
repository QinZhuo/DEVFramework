#include "audio_synth.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>

#include <cmath>
#include <cstring>

using namespace godot;

// Godot Math_TAU
namespace {
constexpr float TAU = 6.283185307179586f;
constexpr float PI = 3.141592653589793f;

static inline int clz32(uint32_t x) {
#if defined(__GNUC__) || defined(__clang__)
	return __builtin_clz(x);
#else
	unsigned long index;
	_BitScanReverse(&index, x);
	return 31 - (int)index;
#endif
}
} // namespace

// ==================== PCG32 (Godot RandomNumberGenerator 兼容) ====================

void AudioSynthEngine::Pcg32::seed(uint64_t p_seed) {
	// PCG_DEFAULT_INC_64 = 1442695040888963407ULL
	inc = (1442695040888963407ULL << 1u) | 1u;
	state = 0;
	next();
	state += p_seed;
	next();
}

uint32_t AudioSynthEngine::Pcg32::next() {
	uint64_t oldstate = state;
	state = oldstate * 6364136223846793005ULL + inc;
	uint32_t xorshifted = (uint32_t)(((oldstate >> 18u) ^ oldstate) >> 27u);
	uint32_t rot = (uint32_t)(oldstate >> 59u);
	return (xorshifted >> rot) | (xorshifted << ((-rot) & 31u));
}

float AudioSynthEngine::Pcg32::randf() {
	uint32_t proto_exp_offset = next();
	if (proto_exp_offset == 0) {
		return 0.0f;
	}
	return ldexpf((float)(next() | 0x80000001u), -32 - clz32(proto_exp_offset));
}

float AudioSynthEngine::Pcg32::random(float from, float to) {
	return from + randf() * (to - from);
}

// ==================== ADSR ====================

void AudioSynthEngine::Adsr::note_on() {
	phase = 0;
	timer = 0.0f;
	start_level = godot::MAX(level, 0.0f);
}

void AudioSynthEngine::Adsr::note_off() {
	if (phase >= 0 && phase <= 2) {
		phase = 3;
		timer = 0.0f;
		start_level = level;
	}
}

static inline float curve_segment(float a, float b, float t, float curve) {
	if (std::fabs(curve) < 0.001f) {
		return a + (b - a) * t;
	}
	if (curve > 0.0f) {
		return a + (b - a) * std::pow(t, 1.0f + curve);
	}
	return a + (b - a) * std::pow(t, 1.0f / (1.0f - curve));
}

float AudioSynthEngine::Adsr::process() {
	float dt = 1.0f / sample_rate;
	timer += dt;
	switch (phase) {
		case 0: {
			float t0 = (attack <= 0.0f) ? 1.0f : timer / attack;
			level = curve_segment(start_level, 1.0f, godot::CLAMP(t0, 0.0f, 1.0f), curve);
			if (timer >= attack) {
				phase = 1;
				timer = 0.0f;
			}
			break;
		}
		case 1: {
			float t1 = (decay <= 0.0f) ? 1.0f : timer / decay;
			level = curve_segment(1.0f, sustain, godot::CLAMP(t1, 0.0f, 1.0f), curve);
			if (timer >= decay) {
				phase = 2;
			}
			break;
		}
		case 2:
			level = sustain;
			break;
		case 3: {
			float t3 = (release <= 0.0f) ? 1.0f : timer / release;
			level = curve_segment(start_level, 0.0f, godot::CLAMP(t3, 0.0f, 1.0f), curve);
			if (timer >= release) {
				phase = -1;
				level = 0.0f;
			}
			break;
		}
	}
	return level;
}

// ==================== SVF 滤波 ====================

float AudioSynthEngine::Svf::process(float x) {
	float f = 2.0f * std::sin(PI * godot::CLAMP(cutoff, 20.0f, sample_rate * 0.45f) / sample_rate);
	float q = 2.0f * (1.0f - godot::CLAMP(resonance, 0.0f, 1.0f)) + 0.5f;
	low += f * band;
	float high = x - low - q * band;
	band = f * high + band;
	switch (mode) {
		case 1:
			return band;
		case 2:
			return high;
	}
	return low;
}

// ==================== 振荡器 ====================

float AudioSynthEngine::poly_blep(float t, float dt) {
	if (t < dt) {
		t /= dt;
		return t + t - t * t - 1.0f;
	} else if (t > 1.0f - dt) {
		t = (t - 1.0f) / dt;
		return t * t + t + t + 1.0f;
	}
	return 0.0f;
}

float AudioSynthEngine::wrap(float p) {
	return p - std::floor(p);
}

float AudioSynthEngine::osc(int wave, float phase, float dt, float duty, Pcg32 &rng, float phase_mod) {
	// phase_mod 为弧度偏移(FM 调制), 转成相位增量叠加到相位上
	float p = phase + phase_mod / TAU;
	switch (wave) {
		case WAVE_SINE:
			return std::sin(p * TAU);
		case WAVE_SQUARE: {
			float s = (p < 0.5f) ? 1.0f : -1.0f;
			s += poly_blep(p, dt) - poly_blep(wrap(p + 0.5f), dt);
			return s;
		}
		case WAVE_SAW: {
			float s = 2.0f * p - 1.0f;
			s -= poly_blep(p, dt);
			return s;
		}
		case WAVE_TRIANGLE: {
			float s = 2.0f * p - 1.0f;
			s -= poly_blep(p, dt);
			float p2 = wrap(p + 0.5f);
			float s2 = 2.0f * p2 - 1.0f;
			s2 -= poly_blep(p2, dt);
			return (s - s2) * 0.5f;
		}
		case WAVE_PULSE: {
			float s = (p < duty) ? 1.0f : -1.0f;
			s += poly_blep(p, dt) - poly_blep(wrap(p - duty + 1.0f), dt);
			return s;
		}
		case WAVE_NOISE:
			return rng.random(-1.0f, 1.0f);
	}
	return 0.0f;
}

// ==================== 配置 ====================

void AudioSynthEngine::configure(const PackedFloat32Array &p_voice_params, const PackedInt32Array &p_osc_counts, int p_sample_rate) {
	_valid = false;
	_voices.clear();
	if (p_sample_rate <= 0) {
		ERR_PRINT("AudioSynthEngine: 采样率必须 > 0");
		return;
	}
	_sample_rate = p_sample_rate;
	if (p_osc_counts.size() <= 0) {
		ERR_PRINT("AudioSynthEngine: 无声部");
		return;
	}
	int off = 0;
	for (int vi = 0; vi < p_osc_counts.size(); ++vi) {
		Voice v;
		v.rng.seed(PCG_SEED);
		_parse_voice(p_voice_params, off, p_osc_counts[vi], v);
		off += VHEAD + p_osc_counts[vi] * OSC_STRIDE;
		_voices.push_back(std::move(v));
	}
	_valid = true;
}

void AudioSynthEngine::_parse_voice(const PackedFloat32Array &p, int s, int osc_count, Voice &out) {
	out.kind = (int)p[s];
	out.volume = p[s + 1];
	out.pan = p[s + 2];
	out.noise_amount = p[s + 3];
	out.vibrato_rate = p[s + 4];
	out.vibrato_depth = p[s + 5];
	out.glide = p[s + 6];
	out.drum_type = (int)p[s + 7];
	out.drum_freq = p[s + 8];
	out.drum_tone = p[s + 9];
	out.drum_noise = p[s + 10];
	// [s+11] = drum_length(已废弃, 占位保持布局稳定, 不读)
	out.env_attack = p[s + 12];
	out.env_decay = p[s + 13];
	out.env_sustain = p[s + 14];
	out.env_release = p[s + 15];
	out.env_curve = p[s + 16];
	out.filt_enabled = p[s + 17] > 0.5f;
	out.filt_mode = (int)p[s + 18];
	out.filt_cutoff = p[s + 19];
	out.filt_resonance = p[s + 20];
	out.filt_env_amount = p[s + 21];
	out.filt_lfo_amount = p[s + 22];
	// [s+23] = n_osc (冗余, 以 osc_counts 为准)
	// LFO 自动化(s+24..s+31)
	out.lfo_enabled = p[s + 24] > 0.5f;
	out.lfo_rate = p[s + 25];
	out.lfo_waveform = (int)p[s + 26];
	out.lfo_depth = p[s + 27];
	out.mod_cutoff = p[s + 28] > 0.5f;
	out.mod_volume = p[s + 29] > 0.5f;
	out.mod_pan = p[s + 30] > 0.5f;
	out.mod_pitch = p[s + 31] > 0.5f;
	out.lfo_phase = 0.0f;
	out.lfo_noise_hold = 0.0f;
	out.lfo_current = 0.0f;
	out.oscs.clear();
	int oo = s + VHEAD;
	for (int i = 0; i < osc_count; ++i) {
		OscParam o;
		o.waveform = (int)p[oo];
		o.level = p[oo + 1];
		o.detune = p[oo + 2];
		o.octave = (int)p[oo + 3];
		o.pulse_width = p[oo + 4];
		o.phase_offset = p[oo + 5];
		o.fm_ratio = p[oo + 6];
		o.fm_index = p[oo + 7];
		o.ks_damping = p[oo + 8];
		out.oscs.push_back(o);
		oo += OSC_STRIDE;
	}
}

void AudioSynthEngine::set_events(int p_voice_index, const Array &p_events) {
	if (p_voice_index < 0 || p_voice_index >= (int)_voices.size()) {
		ERR_PRINT("AudioSynthEngine: 声部索引越界");
		return;
	}
	Voice &v = _voices[p_voice_index];
	v.events.clear();
	v.events.reserve((size_t)p_events.size());
	for (int i = 0; i < p_events.size(); ++i) {
		const Dictionary e = p_events[i];
		Event ev;
		ev.start = (int)e["start"];
		ev.duration = (int)e["duration"];
		ev.midi = (int)e["midi"];
		ev.velocity = (float)(double)e["velocity"];
		ev.pitch_cents = e.has("pitch_cents") ? (float)(double)e["pitch_cents"] : 0.0f;
		v.events.push_back(ev);
	}
	v.event_idx = 0;
	v.cursor = 0;
	v.tones.clear();
	v.drums.clear();
}

// ==================== 渲染 ====================

PackedVector2Array AudioSynthEngine::render(int p_count) {
	PackedVector2Array out;
	if (!_valid || p_count <= 0) {
		return out;
	}
	out.resize(p_count);

	Vector2 *w = out.ptrw();
	for (int i = 0; i < p_count; ++i) {
		float l = 0.0f, r = 0.0f;
		for (size_t vi = 0; vi < _voices.size(); ++vi) {
			Voice &v = _voices[vi];
			const uint64_t gi = v.cursor;
			while (v.event_idx < v.events.size() && (uint64_t)v.events[v.event_idx].start <= gi) {
				_trigger(v, v.events[v.event_idx], gi);
				++v.event_idx;
			}
			// 每采样推进 LFO(供声部内所有音符共用: 滤波/音量/音高/声像调制)
			if (v.lfo_enabled) {
				v.lfo_current = _lfo_value(v);
			}
			float mono = (v.kind == 1) ? _render_drum(v, gi) : _render_tones(v, gi);
			// 声像(可被 LFO 自动声像调制)
			float pan = v.pan;
			if (v.lfo_enabled && v.mod_pan) {
				pan = godot::CLAMP(v.pan + v.lfo_current * v.lfo_depth, -1.0f, 1.0f);
			}
			float gl = std::cos((pan + 1.0f) * PI / 4.0f) * v.volume;
			float gr = std::sin((pan + 1.0f) * PI / 4.0f) * v.volume;
			l += mono * gl;
			r += mono * gr;
			++v.cursor;
		}
		w[i] = Vector2(l, r);
	}
	return out;
}

float AudioSynthEngine::_lfo_value(Voice &v) {
	float old = v.lfo_phase;
	v.lfo_phase += v.lfo_rate / (float)_sample_rate;
	v.lfo_phase -= std::floor(v.lfo_phase);
	switch (v.lfo_waveform) {
		case WAVE_SINE:
			return std::sin(old * TAU);
		case WAVE_TRIANGLE:
			return 2.0f * std::fabs(2.0f * (old - std::floor(old + 0.5f))) - 1.0f;
		case WAVE_SAW:
			return 2.0f * old - 1.0f;
		case WAVE_SQUARE:
			return (old < 0.5f) ? -1.0f : 1.0f;
		case WAVE_NOISE: {
			// 随机采样保持: 每周期更新一次
			float next = old + v.lfo_rate / (float)_sample_rate;
			if (std::floor(next) != std::floor(old)) {
				v.lfo_noise_hold = v.rng.random(-1.0f, 1.0f);
			}
			return v.lfo_noise_hold;
		}
	}
	return 0.0f;
}

void AudioSynthEngine::reset_stream() {
	for (Voice &v : _voices) {
		v.cursor = 0;
		v.event_idx = 0;
		v.tones.clear();
		v.drums.clear();
		v.lfo_phase = 0.0f;
		v.lfo_noise_hold = 0.0f;
		v.lfo_current = 0.0f;
		// 重置 RNG: 保证循环重放时噪声序列与首轮一致(同 seed 必复现)。
		// (旧 GDScript AudioVoice.reset_stream 未重置 rng, 会导致每圈噪声不同, 此处修正)
		v.rng.seed(PCG_SEED);
	}
}

int AudioSynthEngine::get_loop_frames() const {
	int f = 0;
	for (const Voice &v : _voices) {
		for (const Event &e : v.events) {
			f = godot::MAX(f, e.start + e.duration);
		}
	}
	return f;
}

void AudioSynthEngine::_trigger(AudioSynthEngine::Voice &v, const Event &e, uint64_t index) {
	if (v.kind == 1) { // DRUM
		Drum d;
		d.start = e.start;
		d.gate = e.duration;
		d.velocity = e.velocity;
		d.freq = v.drum_freq * ((v.drum_type == 4) ? 3.0f : 1.0f); // TOM = 4
		v.drums.push_back(std::move(d));
		return;
	}
	Tone n;
	n.start = e.start;
	n.gate = e.duration;
	n.velocity = e.velocity;
	n.target_freq = 440.0f * std::pow(2.0f, (e.midi - 69.0f) / 12.0f);
	n.target_freq *= std::pow(2.0f, e.pitch_cents / 1200.0f);
	n.freq = n.target_freq * ((v.glide > 0.0f) ? 0.5f : 1.0f);
	n.phases.assign(v.oscs.size(), 0.0f);
	for (size_t oi = 0; oi < v.oscs.size(); ++oi) {
		n.phases[oi] = v.oscs[oi].phase_offset;  // 相位偏移生效
	}
	n.mod_phases.assign(v.oscs.size(), 0.0f);
	n.ks_bufs.resize(v.oscs.size());
	n.ks_pos.assign(v.oscs.size(), 0u);
	for (size_t oi = 0; oi < v.oscs.size(); ++oi) {
		const OscParam &od = v.oscs[oi];
		if (od.waveform == WAVE_KARPLUS) {
			// 拨弦: 波表大小 = 采样率/频率, 以白噪声初始化, 拨弦瞬间激励
			float f = n.target_freq * std::pow(2.0f, (od.detune + od.octave * 1200.0f) / 1200.0f);
			int size = std::max(2, (int)((float)_sample_rate / std::max(f, 20.0f)));
			n.ks_bufs[oi].resize((size_t)size);
			for (int k = 0; k < size; ++k) {
				n.ks_bufs[oi][k] = v.rng.random(-1.0f, 1.0f);
			}
			n.ks_pos[oi] = 0u;
		}
	}
	n.adsr.sample_rate = (float)_sample_rate;
	n.adsr.attack = v.env_attack;
	n.adsr.decay = v.env_decay;
	n.adsr.sustain = v.env_sustain;
	n.adsr.release = v.env_release;
	n.adsr.curve = v.env_curve;
	if (v.filt_enabled) {
		n.has_filter = true;
		n.filter.sample_rate = (float)_sample_rate;
		n.filter.mode = v.filt_mode;
		n.filter.cutoff = v.filt_cutoff;
		n.filter.resonance = v.filt_resonance;
		n.filter.reset();
	}
	n.adsr.note_on();
	v.tones.push_back(std::move(n));
}

float AudioSynthEngine::_render_tones(AudioSynthEngine::Voice &v, uint64_t index) {
	float sum = 0.0f;
	size_t i = 0;
	while (i < v.tones.size()) {
		Tone &n = v.tones[i];
		if (n.removed) {
			v.tones.erase(v.tones.begin() + i);
			continue;
		}
		sum += _render_tone(v, n, index);
		++i;
	}
	return sum;
}

float AudioSynthEngine::_render_tone(AudioSynthEngine::Voice &v, AudioSynthEngine::Tone &n, uint64_t index) {
	if (!n.removed && index >= (uint64_t)(n.start + n.gate)) {
		n.adsr.note_off();
	}
	if (v.vibrato_depth > 0.0f) {
		float vib = std::sin(n.vibrato_phase * TAU) * v.vibrato_depth * 100.0f;
		n.freq = n.target_freq * std::pow(2.0f, vib / 1200.0f);
		n.vibrato_phase += v.vibrato_rate / (float)_sample_rate;
	} else if (v.glide > 0.0f) {
		float a = 1.0f - std::exp(-1.0f / (godot::MAX(v.glide, 0.0001f) * (float)_sample_rate));
		n.freq = n.freq + (n.target_freq - n.freq) * a;
	}
	// LFO 音高调制(半音; 叠加在颤音/滑音之上, 以目标频率为基准)
	if (v.lfo_enabled && v.mod_pitch) {
		float cents = v.lfo_current * v.lfo_depth * 100.0f;
		n.freq = n.target_freq * std::pow(2.0f, cents / 1200.0f);
	}
	float env = n.adsr.process();
	if (n.adsr.is_done()) {
		n.removed = true;
		return 0.0f;
	}
	float wave = 0.0f;
	for (size_t oi = 0; oi < v.oscs.size(); ++oi) {
		const OscParam &od = v.oscs[oi];
		float f = n.target_freq * std::pow(2.0f, (od.detune + od.octave * 1200.0f) / 1200.0f);
		float dt = f / (float)_sample_rate;
		float ph = n.phases[oi];
		if (od.waveform == WAVE_KARPLUS) {
			// Karplus-Strong 拨弦: 读波表 + 相邻平均低通反馈
			auto &buf = n.ks_bufs[oi];
			if (buf.empty()) {
				n.phases[oi] = ph + dt - std::floor(ph + dt);
				continue;
			}
			uint32_t pos = n.ks_pos[oi];
			float out = buf[pos];
			uint32_t next = pos + 1;
			if (next >= (uint32_t)buf.size()) {
				next = 0;
			}
			buf[pos] = od.ks_damping * (out + buf[next]) * 0.5f;
			n.ks_pos[oi] = next;
			wave += out * od.level;
		} else {
			float mod = 0.0f;
			if (od.fm_index > 0.0f) {
				// FM: 调制器频率 = 载波 × ratio, 调制指数 fm_index
				float mdt = (f * od.fm_ratio) / (float)_sample_rate;
				float mph = n.mod_phases[oi];
				mod = od.fm_index * std::sin(mph * TAU);
				n.mod_phases[oi] = mph + mdt - std::floor(mph + mdt);
			}
			wave += osc(od.waveform, ph, dt, od.pulse_width, v.rng, mod) * od.level;
		}
		n.phases[oi] = ph + dt - std::floor(ph + dt);
	}
	if (v.noise_amount > 0.0f) {
		wave += v.rng.random(-1.0f, 1.0f) * v.noise_amount;
	}
	if (n.has_filter) {
		// 基于基础 cutoff 重算(而非 n.filter.cutoff 累积值): LFO 乘法调制会指数漂移, 从基础算才正确
		float cut = v.filt_cutoff;
		if (v.filt_env_amount != 0.0f) {
			cut += v.filt_env_amount * env;
		}
		// cutoff_lfo_amount: 滤波器截止随声部 LFO 线性调制(配合 AudioLFODef; LFO 关闭时 lfo_current=0 无影响)
		if (v.filt_lfo_amount != 0.0f) {
			cut += v.filt_lfo_amount * v.lfo_current;
		}
		// LFO 滤波扫频: cutoff 在 ±depth 倍之间(1±depth)
		if (v.lfo_enabled && v.mod_cutoff) {
			cut *= (1.0f + v.lfo_current * v.lfo_depth);
		}
		n.filter.cutoff = godot::CLAMP(cut, 20.0f, (float)_sample_rate * 0.45f);
		wave = n.filter.process(wave);
	}
	float gain = env * n.velocity;
	// LFO 音量调制(律动抽吸/颤音)
	if (v.lfo_enabled && v.mod_volume) {
		gain *= (1.0f + v.lfo_current * v.lfo_depth);
	}
	return wave * gain;
}

float AudioSynthEngine::_render_drum(AudioSynthEngine::Voice &v, uint64_t index) {
	float sum = 0.0f;
	size_t i = 0;
	while (i < v.drums.size()) {
		Drum &d = v.drums[i];
		if (d.removed) {
			v.drums.erase(v.drums.begin() + i);
			continue;
		}
		if (index >= (uint64_t)(d.start + d.gate)) {
			d.removed = true;
			continue;
		}
		sum += _drum_sample(v, d, (float)(index - d.start) / (float)_sample_rate);
		++i;
	}
	return sum;
}

float AudioSynthEngine::_drum_sample(AudioSynthEngine::Voice &v, AudioSynthEngine::Drum &d, float t) {
	float noise = v.rng.random(-1.0f, 1.0f);
	switch (v.drum_type) {
		case 0: { // KICK
			float env = std::exp(-t * 34.0f);
			float a = d.freq * 2.6f;
			float f = a + (v.drum_freq - a) * (1.0f - std::exp(-t * 30.0f));
			d.phase += f / (float)_sample_rate;
			float tone = std::sin(d.phase * TAU) * env * v.drum_tone;
			float click = noise * std::exp(-t * 85.0f) * v.drum_noise;
			return tone + click;
		}
		case 1: { // SNARE
			d.phase += 200.0f / (float)_sample_rate;
			float tone = std::sin(d.phase * TAU) * std::exp(-t * 16.0f) * v.drum_tone;
			float nz = noise * std::exp(-t * 20.0f) * v.drum_noise;
			return tone * 0.4f + nz;
		}
		case 2: // HAT_OPEN
			return noise * std::exp(-t * 18.0f) * v.drum_noise * v.drum_tone * 1.2f;
		case 3: // HAT_CLOSED
			return noise * std::exp(-t * 110.0f) * v.drum_noise * v.drum_tone * 1.2f;
		case 4: { // TOM
			float env = std::exp(-t * 16.0f);
			float a = d.freq * 1.6f;
			float f = a + (v.drum_freq - a) * (1.0f - std::exp(-t * 18.0f));
			d.phase += f / (float)_sample_rate;
			return std::sin(d.phase * TAU) * env * v.drum_tone;
		}
		case 5: { // CLAP
			float bursts = 0.0f;
			for (int b = 0; b < 3; ++b) {
				float tb = t - b * 0.012f;
				if (tb > 0.0f) {
					bursts += std::exp(-tb * 70.0f);
				}
			}
			return (noise * bursts * 0.5f + std::sin(t * 180.0f * TAU) * std::exp(-t * 30.0f) * v.drum_tone) * 0.8f;
		}
	}
	return 0.0f;
}

void AudioSynthEngine::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "voice_params", "osc_counts", "sample_rate"), &AudioSynthEngine::configure);
	ClassDB::bind_method(D_METHOD("set_events", "voice_index", "events"), &AudioSynthEngine::set_events);
	ClassDB::bind_method(D_METHOD("render", "count"), &AudioSynthEngine::render);
	ClassDB::bind_method(D_METHOD("reset_stream"), &AudioSynthEngine::reset_stream);
	ClassDB::bind_method(D_METHOD("get_loop_frames"), &AudioSynthEngine::get_loop_frames);
}
