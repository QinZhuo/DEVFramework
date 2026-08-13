#include "pcg_lsystem.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <cmath>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

using namespace godot;

void PCGLSystem::_bind_methods() {
	ClassDB::bind_method(D_METHOD("generate", "axiom", "rules", "iterations",
			"angle_deg", "step_length", "angle_jitter", "draw_on_f", "start_angle",
			"origin", "max_segments", "seed"),
			&PCGLSystem::generate);
}

PackedVector2Array PCGLSystem::generate(const String &axiom, const Dictionary &rules,
		int iterations, float angle_deg, float step_length, float angle_jitter,
		bool draw_on_f, float start_angle, const Vector2 &origin,
		int max_segments, int seed) {
	PackedVector2Array segs;
	if (max_segments <= 0)
		return segs;
	// 规则表: char -> replacement std::string
	std::unordered_map<char, std::string> rule_map;
	Array rule_keys = rules.keys();
	Array rule_values = rules.values();
	for (int i = 0; i < rule_keys.size(); ++i) {
		String ks = String(rule_keys[i]);
		String vs = String(rule_values[i]);
		if (!ks.is_empty())
			rule_map[(char)ks.unicode_at(0)] = vs.utf8().get_data();
	}
	// 迭代重写
	std::string current = axiom.utf8().get_data();
	for (int it = 0; it < iterations; ++it) {
		std::string next;
		next.reserve(current.size() * 3);
		for (char ch : current) {
			auto found = rule_map.find(ch);
			if (found != rule_map.end())
				next += found->second;
			else
				next += ch;
			// 爆炸保护
			if (next.size() > (size_t)max_segments * 4) {
				current = next;
				goto turtle;
			}
		}
		current = std::move(next);
	}
turtle:
	// turtle 解释
	float angle_rad = angle_deg * (float)M_PI / 180.0f;
	float jitter_rad = angle_jitter * (float)M_PI / 180.0f;
	double pos_x = origin.x;
	double pos_y = origin.y;
	double heading = start_angle * (float)M_PI / 180.0f;
	// 栈: pos + heading
	struct State { double x, y, h; };
	std::vector<State> stack;
	stack.reserve(256);
	std::mt19937_64 rng((uint64_t)seed);
	std::uniform_real_distribution<double> unit(0.0, 1.0);
	segs.resize(max_segments * 2); // 预留, 防止 PackedArray 反复扩容
	int seg_count = 0;
	for (char ch : current) {
		if (seg_count >= max_segments)
			break;
		if (ch == 'F' || ch == 'G') {
			double j = 0.0;
			if (jitter_rad > 0.0)
				j = (unit(rng) - 0.5) * 2.0 * jitter_rad;
			double h = heading + j;
			double tx = pos_x + std::cos(h) * step_length;
			double ty = pos_y + std::sin(h) * step_length;
			if (ch == 'F' && draw_on_f) {
				segs[seg_count * 2] = Vector2((float)pos_x, (float)pos_y);
				segs[seg_count * 2 + 1] = Vector2((float)tx, (float)ty);
				++seg_count;
			}
			pos_x = tx;
			pos_y = ty;
		} else if (ch == '+') {
			heading += angle_rad;
		} else if (ch == '-') {
			heading -= angle_rad;
		} else if (ch == '[') {
			stack.push_back({pos_x, pos_y, heading});
		} else if (ch == ']') {
			if (!stack.empty()) {
				State s = stack.back();
				stack.pop_back();
				pos_x = s.x;
				pos_y = s.y;
				heading = s.h;
			}
		}
	}
	segs.resize(seg_count * 2);
	return segs;
}
