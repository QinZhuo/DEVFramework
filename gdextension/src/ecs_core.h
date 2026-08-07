#ifndef DECS_ECS_CORE_H
#define DECS_ECS_CORE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <cstdint>
#include <vector>

namespace godot {

// ---------------------------------------------------------------------------
// 稀疏集: 实体 <-> 行号 双向映射 (EnTT 风格)
//   dense[row]  = entity    行号连续, 遍历缓存友好
//   sparse[e]   = row       O(1) 判断实体是否拥有该组件
// ---------------------------------------------------------------------------
struct ECSSparseSet {
	std::vector<int32_t> dense;
	std::vector<int32_t> sparse; // 实体 -> 行号, -1 = 无

	int32_t add(int32_t entity);
	void remove(int32_t entity);
	bool has(int32_t entity) const { return int32_t(entity) < int32_t(sparse.size()) && sparse[entity] >= 0; }
	int32_t row_of(int32_t entity) const {
		return (int32_t(entity) < int32_t(sparse.size()) && sparse[entity] >= 0) ? sparse[entity] : -1;
	}
	inline size_t size() const { return dense.size(); }
};

// ---------------------------------------------------------------------------
// SoA 列存储: 每组件每字段一块连续内存 (标量类型直存, 无对象无引用)
// ---------------------------------------------------------------------------
struct ECSColumn {
	Variant::Type type = Variant::NIL;
	std::vector<int32_t> i32;   // INT
	std::vector<float> f32;     // FLOAT
	std::vector<uint8_t> b;     // BOOL
	std::vector<Vector2> v2;    // VECTOR2
	std::vector<Vector3> v3;    // VECTOR3
	std::vector<Color> col;     // COLOR
	std::vector<String> s;      // STRING

	void resize(size_t n);
	void push_default(const Variant &value);
	Variant get(size_t row) const;
	void set(size_t row, const Variant &value);
	size_t size() const;
};

struct ECSField {
	StringName name;
	Variant::Type type;
};

struct ECSComponentData {
	StringName name;
	std::vector<ECSField> fields;
	std::vector<ECSColumn> columns;
	std::vector<Variant> defaults; // 每字段默认值, add_component 时填充新行
	ECSSparseSet set;

	int field_index(const StringName &f) const;
	inline ECSColumn &column(int fi) { return columns[fi]; }
	inline const ECSColumn &column(int fi) const { return columns[fi]; }
};

// ---------------------------------------------------------------------------
// ECSCore — 唯一对外原生类 (GDScript 侧经 ECSNative 桥接访问)
// ---------------------------------------------------------------------------
class ECSCore : public RefCounted {
	GDCLASS(ECSCore, RefCounted)

protected:
	static void _bind_methods();

public:
	// ---- 组件注册 ----
	// name: 组件类名; fnames: 字段名; ftypes: 字段 Variant::Type; fdefaults: 默认值
	int32_t register_component(const StringName &name, const PackedStringArray &fnames,
			const PackedInt32Array &ftypes, const Array &fdefaults);

	// ---- 实体 ----
	int32_t create_entity();
	bool is_alive(int32_t entity) const;
	void destroy_entity(int32_t entity);

	// ---- 组件增删查 ----
	bool add_component(int32_t entity, const StringName &comp);
	bool has_component(int32_t entity, const StringName &comp) const;
	void remove_component(int32_t entity, const StringName &comp);
	int32_t count_entities(const StringName &comp) const;

	// ---- 查询 ----
	// 返回 anchor 组件 dense 中同时拥有 must 且不拥有 without 的实体 ID 列表。
	// 列按实体 ID 直接索引, 返回的 ID 可直接索引任意组件的列。
	PackedInt32Array query_rows(const StringName &anchor, const PackedStringArray &must,
			const PackedStringArray &without) const;
	int32_t entity_of_row(const StringName &comp, int32_t row) const;

	// ---- 单实体字段访问 (低频路径) ----
	Variant get_field(int32_t entity, const StringName &comp, const StringName &field) const;
	void set_field(int32_t entity, const StringName &comp, const StringName &field, const Variant &value);

	// ---- 批量列访问 (高频路径: 整列拷贝给 GDScript 本地循环, 再整列写回) ----
	Variant get_column(const StringName &comp, const StringName &field) const;
	void set_column(const StringName &comp, const StringName &field, const Variant &values);

	// ---- Tier 0: 原生批量运算 (纯 C++ 循环, 无 GDScript 解释开销) ----
	// 对 anchor 组件 dense 中满足 must 的实体, 原地执行 op。
	// op 用于 int/float 列: op_comp+op_field 为被修改字段, factor 为系数,
	// addend 为加数。支持两种模式:
	//   MODE_ADD     : col = col + addend            (如 hp += 5)
	//   MODE_MUL_ADD : col = col * factor + addend   (如 hp = min(max, hp*0.9+2))
	// 返回被处理的实体数。
	enum BatchOp { BATCH_ADD = 0, BATCH_MUL_ADD = 1, BATCH_SET = 2, BATCH_CLAMP = 3 };
	int64_t batch_apply(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field, int64_t op,
			double factor, double addend);
	// 边界钳制: col = clamp(col, min_val, max_val), min/max 取自另一组件字段
	int64_t batch_clamp(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field,
			const StringName &min_comp, const StringName &min_field,
			const StringName &max_comp, const StringName &max_field);
	// 向量批量: 对 Vector2/3 列按实体逐项加(速度/位置积分)
	int64_t batch_vec_add(const StringName &anchor, const PackedStringArray &must,
			const StringName &pos_comp, const StringName &pos_field,
			const StringName &vel_comp, const StringName &vel_field, double delta);

private:
	ECSComponentData *find_comp(const StringName &name);
	const ECSComponentData *find_comp(const StringName &name) const;

	std::vector<ECSComponentData> components_;
	// 实体池: index | (version << 24), 复用防悬垂
	std::vector<uint32_t> versions_;
	std::vector<int32_t> free_list_;
};

} // namespace godot

#endif // DECS_ECS_CORE_H
