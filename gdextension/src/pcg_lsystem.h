#ifndef DECS_PCG_LSYSTEM_H
#define DECS_PCG_LSYSTEM_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <random>

namespace godot {

// ---------------------------------------------------------------------------
// PCGLSystem — L-System 生长展开（C++, 大迭代加速）。
//
// 与 GDScript 版 PCGTool.generate_lsystem 同算法：
//   迭代重写(公理 → 规则展开) + turtle 解释(F/G 前进画线, +/-转向, [ ] 分支栈)。
// C++ 用 std::string 做字符串展开(避免 GDScript 字符串拼接开销), 大迭代快数十倍。
//
// 接口(供 FrameworkNative.get_native(&"PCGLSystem") 访问):
//   generate(axiom: String, rules: Dictionary, iterations: int,
//            angle_deg: float, step_length: float, angle_jitter: float,
//            draw_on_f: bool, start_angle: float, origin: Vector2,
//            max_segments: int, seed: int) -> PackedVector2Array
//   returns 线段集(每对相邻点 = 一条线段), 长度受 max_segments 保护。
// 纯函数式, 线程安全。
// ---------------------------------------------------------------------------
class PCGLSystem : public RefCounted {
	GDCLASS(PCGLSystem, RefCounted)

protected:
	static void _bind_methods();

public:
	PackedVector2Array generate(const String &axiom, const Dictionary &rules,
			int iterations, float angle_deg, float step_length, float angle_jitter,
			bool draw_on_f, float start_angle, const Vector2 &origin,
			int max_segments, int seed);
};

} // namespace godot

#endif // DECS_PCG_LSYSTEM_H
