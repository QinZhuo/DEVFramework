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
// 稀疏集: 实体 <-> dense 行号 双向映射 (EnTT 风格)
//   dense[row]  = entity    拥有该组件的实体, 行号连续
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
// SoA 列存储: 每组件每字段一块连续内存。
// 用 Godot Packed*Array 直接存储:
//   - get_column 返回内部引用 (Variant 包装, 共享底层内存, 零拷贝)
//   - set_column 引用赋值 (指针交换, 无逐元素拷贝)
// 列下标 = 实体 ID (所有组件共享同一实体 ID 索引空间, 跨组件对齐)
// ---------------------------------------------------------------------------
struct ECSColumn {
	Variant::Type type = Variant::NIL;
	PackedInt32Array i32;   // INT
	PackedFloat32Array f32; // FLOAT
	PackedByteArray b;      // BOOL
	PackedVector2Array v2;  // VECTOR2
	PackedVector3Array v3;  // VECTOR3
	PackedColorArray col;   // COLOR
	PackedStringArray s;    // STRING

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
// 组件签名 (有序组件索引列表) -> 聚簇组
// 用于: 同签名实体 ID 连续分配, 遍历时缓存友好
// ---------------------------------------------------------------------------
struct ECSSignature {
	std::vector<int32_t> comps; // 升序组件索引
	// 聚簇 ID 池: 本签名实体复用的 ID(保证同签名实体 ID 数值接近)
	std::vector<int32_t> free_ids;
	int32_t next_hint = 0; // 分配游标
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
	// 返回匹配实体的实体 ID 列表(可直接索引任意组件列)。
	PackedInt32Array query_rows(const StringName &anchor, const PackedStringArray &must,
			const PackedStringArray &without) const;
	int32_t entity_of_row(const StringName &comp, int32_t row) const;

	// ---- 单实体字段访问 (低频路径) ----
	Variant get_field(int32_t entity, const StringName &comp, const StringName &field) const;
	void set_field(int32_t entity, const StringName &comp, const StringName &field, const Variant &value);

	// ---- 批量列访问 (零拷贝: 返回内部 Packed*Array 引用) ----
	Variant get_column(const StringName &comp, const StringName &field) const;
	void set_column(const StringName &comp, const StringName &field, const Variant &values);

	// ---- Tier 0: 原生批量运算 (纯 C++ 循环, 无 GDScript 解释开销) ----
	enum BatchOp { BATCH_ADD = 0, BATCH_MUL_ADD = 1, BATCH_SET = 2, BATCH_CLAMP = 3 };
	// 条件比较符
	enum CondOp { COND_LT = 0, COND_LE = 1, COND_GT = 2, COND_GE = 3, COND_EQ = 4, COND_NE = 5 };
	// batch_apply 带条件版本: conditions 为 Array[Dictionary], 每项 {comp, field, op, value}
	// 仅对满足全部条件的实体执行 op。返回处理的实体数。
	int64_t batch_apply_where(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field, int64_t op,
			double factor, double addend, const Array &conditions);
	// 统计满足条件的实体数(纯查询, 不修改)
	int64_t batch_count(const StringName &anchor, const PackedStringArray &must,
			const Array &conditions) const;
	int64_t batch_apply(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field, int64_t op,
			double factor, double addend);
	int64_t batch_clamp(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field,
			const StringName &min_comp, const StringName &min_field,
			const StringName &max_comp, const StringName &max_field);
	int64_t batch_vec_add(const StringName &anchor, const PackedStringArray &must,
			const StringName &pos_comp, const StringName &pos_field,
			const StringName &vel_comp, const StringName &vel_field, double delta);

	// 内存统计(调试)
	Dictionary debug_stats() const;

	// ---- 序列化/反序列化 (对接 SaveTool 存档) ----
	// 序列化整个世界: 返回 {components: [{name, fields:[{name,type}], defaults:[...],
	//   entities: [{entity, values:[...]}]}], pool_size}
	// 字段值按注册顺序排列; 无组件实体不参与(仅组件数据)。
	Dictionary serialize() const;
	// 反序列化: 重建组件注册 + 实体 + 数据。
	// 返回 Array[int]: 新建实体的真实实体 ID 列表(调用方用它绑定 EntityView 等)。
	// 注意: 需先 register_component 同名的组件(名称一致), 否则忽略该组件数据。
	Array deserialize(const Dictionary &data);

	// 供条件过滤解析内部使用
	const ECSComponentData *find_comp(const StringName &name) const;

private:
	// ---- 内部 ----
	ECSComponentData *find_comp(const StringName &name);
	int32_t comp_index(const StringName &name) const;

	// 签名聚簇: 实体 ID 分配
	int32_t sig_index_for(const std::vector<int32_t> &comps);
	int32_t allocate_entity_id();
	void release_entity_id(int32_t index);

	// ---- 存储 ----
	std::vector<ECSComponentData> components_;
	std::vector<ECSSignature> signatures_;
	// 实体池: index | (version << 24), 复用防悬垂
	std::vector<uint32_t> versions_;
	std::vector<int32_t> free_list_;
};

} // namespace godot

#endif // DECS_ECS_CORE_H
