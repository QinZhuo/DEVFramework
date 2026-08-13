#include "pcg_cave3d.h"

#include <godot_cpp/core/class_db.hpp>
#include <algorithm>
#include <cstdint>

using namespace godot;

void PCGCave3D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("generate", "width", "height", "depth", "seed",
			"cave_ratio", "smooth_passes", "border_solid", "solid_value", "empty_value"),
			&PCGCave3D::generate);
}

PackedInt32Array PCGCave3D::generate(int p_width, int p_height, int p_depth,
		int seed, float cave_ratio, int smooth_passes, bool border_solid,
		int solid_value, int empty_value) {
	PackedInt32Array result;
	if (p_width <= 0 || p_height <= 0 || p_depth <= 0)
		return result;
	int cell_count = p_width * p_height * p_depth;
	result.resize(cell_count);
	std::vector<int32_t> cells((size_t)cell_count);
	std::vector<int32_t> next((size_t)cell_count);

	std::mt19937 rng((uint32_t)seed);
	std::uniform_real_distribution<float> unit(0.0f, 1.0f);
	// 初始随机填充
	for (int i = 0; i < cell_count; ++i)
		cells[i] = (unit(rng) < cave_ratio) ? solid_value : empty_value;

	// 26 邻域平滑
	for (int pass = 0; pass < smooth_passes; ++pass) {
		next = cells;
		int idx = 0;
		for (int z = 0; z < p_depth; ++z) {
			for (int y = 0; y < p_height; ++y) {
				for (int x = 0; x < p_width; ++x, ++idx) {
					int walls = 0;
					for (int dz = -1; dz <= 1; ++dz) {
						int nz = z + dz;
						for (int dy = -1; dy <= 1; ++dy) {
							int ny = y + dy;
							for (int dx = -1; dx <= 1; ++dx) {
								if (dx == 0 && dy == 0 && dz == 0)
									continue;
								int nx = x + dx;
								if (nx < 0 || nx >= p_width || ny < 0 || ny >= p_height || nz < 0 || nz >= p_depth) {
									if (border_solid)
										++walls;
									continue;
								}
								int ni = (nz * p_height + ny) * p_width + nx;
								if (cells[ni] == solid_value)
									++walls;
							}
						}
					}
					next[idx] = (walls >= 13) ? solid_value : empty_value;
				}
			}
		}
		cells.swap(next);
	}
	for (int i = 0; i < cell_count; ++i)
		result[i] = cells[i];
	return result;
}
