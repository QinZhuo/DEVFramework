#ifndef DECS_AUDIO_SYNTH_H
#define DECS_AUDIO_SYNTH_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstdint>
#include <vector>

namespace godot {

// ---------------------------------------------------------------------------
// AudioSynthEngine — 程序化音频合成核心 (C++)。
//
// 与 GDScript 版 AudioVoice + AudioTool 的逐采样合成内核同算法(1:1 移植),
// 负责最耗 CPU 的部分: 多声部逐采样合成(振荡器+PolyBLEP+SVF滤波+ADSR包络+
// 颤音/滑音+噪声+物理建模鼓), 并按每声部 pan/volume 混合成立体声。
//
// 设计:
//   - 配置一次(configure), 渲染多次: 声部参数以 PackedFloat32Array 扁平传入,
//     避免每采样读取 Godot Resource 反射属性(性能关键)。
//   - 事件(Array[Dictionary]) 在 set_events 时解析并缓存到内部结构。
//   - render(count) 流式渲染, 支持循环(reset_stream)。
//   - 噪声用 PCG32 + Godot 的 randf 算法(seed 固定 123456),
//     与 GDScript RandomNumberGenerator 输出一致, 保证迁移前后同 seed 可复现。
//
// 用法:
//   var engine := FrameworkNative.get_native(&"AudioSynthEngine", [&"configure", &"render"])
//   engine.configure(voice_params, osc_counts, 22050)
//   engine.set_events(0, [...])
//   var frames: PackedVector2Array = engine.render(2048)
// ---------------------------------------------------------------------------
class AudioSynthEngine : public RefCounted {
	GDCLASS(AudioSynthEngine, RefCounted)

public:
	// 配置声部。voice_params 布局(每声部, 浮点):
//   [0] kind(0=TONE,1=DRUM) [1]volume [2]pan [3]noise_amount [4]vibrato_rate
//   [5]vibrato_depth [6]glide [7]drum_type [8]drum_freq [9]drum_tone
//   [10]drum_noise [11]drum_length [12]env.attack [13]env.decay [14]env.sustain
//   [15]env.release [16]env.curve [17]filt.enabled [18]filt.mode [19]filt.cutoff
//   [20]filt.resonance [21]filt.env_amount [22]filt.lfo_amount [23]n_osc
//   随后每振荡器 9 个: [waveform, level, detune_cents, octave_shift, pulse_width,
//   phase_offset, fm_ratio, fm_index, ks_damping]
	void configure(const PackedFloat32Array &p_voice_params, const PackedInt32Array &p_osc_counts, int p_sample_rate);

	// 设置某声部的事件数组。事件为 Dictionary: {start:int, duration:int, midi:int, velocity:float, pitch_cents:float}
	void set_events(int p_voice_index, const Array &p_events);

	// 从当前游标渲染 count 帧立体声(左右交错混合全部声部)。
	PackedVector2Array render(int p_count);

	// 重置流游标(循环/重新播放用)。
	void reset_stream();

	// 全部事件的最大结束帧(循环长度); 无声部/事件返回 0。
	int get_loop_frames() const;

protected:
	static void _bind_methods();

private:
	// ---- 常量(与 GDScript 端打包布局一致) ----
	static const int VHEAD = 32;       // 每声部头部标量数
	static const int OSC_STRIDE = 9;   // 每振荡器标量数
	static const int PCG_SEED = 123456;

	// ---- 枚举 ----
	enum Wave { WAVE_SINE, WAVE_SQUARE, WAVE_SAW, WAVE_TRIANGLE, WAVE_PULSE, WAVE_NOISE, WAVE_KARPLUS };
	enum FilterMode { FILTER_LOW_PASS, FILTER_BAND_PASS, FILTER_HIGH_PASS };

public:
	// ---- PCG32 (Godot RandomNumberGenerator 兼容) ----
	struct Pcg32 {
		uint64_t state = 0;
		uint64_t inc = 0;
		Pcg32() { seed(PCG_SEED); }
		void seed(uint64_t p_seed);
		uint32_t next();
		float randf();
		float random(float from, float to);
	};

	// ---- ADSR 包络 (Godot AudioTool.ADSR 同算法) ----
	struct Adsr {
		float sample_rate = 44100.0f;
		float attack = 0.005f, decay = 0.1f, sustain = 0.7f, release = 0.2f, curve = 0.0f;
		int phase = -1;
		float timer = 0.0f, start_level = 0.0f, level = 0.0f;
		void note_on();
		void note_off();
		bool is_done() const { return phase == -1; }
		float process();
	};

	// ---- SVF 状态变量滤波 (AudioTool.SVFilter 同算法) ----
	struct Svf {
		float sample_rate = 44100.0f;
		int mode = 0;
		float cutoff = 8000.0f, resonance = 0.3f;
		float low = 0.0f, band = 0.0f;
		void reset() { low = band = 0.0f; }
		float process(float x);
	};

	// ---- 振荡器 ----
	static float poly_blep(float t, float dt);
	static float wrap(float p);
	float osc(int wave, float phase, float dt, float duty, Pcg32 &rng, float phase_mod = 0.0f);

	// ---- 发声音符状态 ----
	struct Tone {
		int start = 0, gate = 0;
		float target_freq = 440.0f, freq = 440.0f, velocity = 1.0f;
		float vibrato_phase = 0.0f;
		std::vector<float> phases;
		// FM 调制器相位(每振荡器一个, 仅 fm_index>0 时使用)
		std::vector<float> mod_phases;
		// Karplus-Strong 拨弦波表(每振荡器一个; 用 vector-of-vector 保持每振荡器独立)
		std::vector<std::vector<float>> ks_bufs;
		std::vector<uint32_t> ks_pos;
		Adsr adsr;
		Svf filter;
		bool has_filter = false;
		bool removed = false;
	};

	struct Drum {
		int start = 0, gate = 0;
		float velocity = 1.0f, phase = 0.0f, freq = 90.0f;
		bool removed = false;
	};

	struct OscParam {
		int waveform = WAVE_SINE;
		float level = 1.0f, detune = 0.0f, pulse_width = 0.5f;
		int octave = 0;
		float fm_ratio = 1.0f, fm_index = 0.0f, ks_damping = 0.5f;
		float phase_offset = 0.0f;
	};

	struct Event {
		int start = 0, duration = 0, midi = 0;
		float velocity = 1.0f, pitch_cents = 0.0f;
	};

	struct Voice {
		int kind = 0;
		float volume = 0.8f, pan = 0.0f, noise_amount = 0.0f;
		float vibrato_rate = 5.0f, vibrato_depth = 0.0f, glide = 0.0f;
		int drum_type = 0;
		float drum_freq = 90.0f, drum_tone = 0.6f, drum_noise = 0.4f;
		// 包络
		float env_attack = 0.005f, env_decay = 0.1f, env_sustain = 0.7f, env_release = 0.2f, env_curve = 0.0f;
		// 滤波
		bool filt_enabled = false;
		int filt_mode = 0;
		float filt_cutoff = 8000.0f, filt_resonance = 0.3f;
		float filt_env_amount = 0.0f, filt_lfo_amount = 0.0f;
		// LFO 自动化
		bool lfo_enabled = false;
		float lfo_rate = 5.0f;
		int lfo_waveform = 0;
		float lfo_depth = 0.5f;
		bool mod_cutoff = false, mod_volume = false, mod_pan = false, mod_pitch = false;
		float lfo_phase = 0.0f, lfo_noise_hold = 0.0f, lfo_current = 0.0f;
		std::vector<OscParam> oscs;
		// 运行时
		std::vector<Tone> tones;
		std::vector<Drum> drums;
		Pcg32 rng;
		uint64_t cursor = 0;
		uint32_t event_idx = 0;
		std::vector<Event> events;
	};

	bool _valid = false;
	int _sample_rate = 22050;
	std::vector<Voice> _voices;

	void _parse_voice(const PackedFloat32Array &p, int p_start, int p_osc_count, Voice &out);

	void _trigger(Voice &v, const Event &e, uint64_t index);
	float _lfo_value(Voice &v);
	float _render_tones(Voice &v, uint64_t index);
	float _render_tone(Voice &v, Tone &n, uint64_t index);
	float _render_drum(Voice &v, uint64_t index);
	float _drum_sample(Voice &v, Drum &d, float t);
};

} // namespace godot

#endif // DECS_AUDIO_SYNTH_H
