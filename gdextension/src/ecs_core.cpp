#include "ecs_core.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <unordered_map>

using namespace godot;

// ---------------------------------------------------------------------------
// ECSSparseSet
// ---------------------------------------------------------------------------

int32_t ECSSparseSet::add(int32_t entity) {
	const int32_t e = entity;
	if (int32_t(sparse.size()) <= e) {
		sparse.resize(e + 1, -1);
	}
	if (sparse[e] >= 0) {
		return sparse[e]; // 已存在
	}
	const int32_t row = int32_t(dense.size());
	sparse[e] = row;
	dense.push_back(e);
	return row;
}

void ECSSparseSet::remove(int32_t entity) {
	if (int32_t(sparse.size()) <= entity || sparse[entity] < 0) {
		return;
	}
	const int32_t row = sparse[entity];
	const int32_t last_entity = dense.back();
	dense[row] = last_entity;
	sparse[last_entity] = row;
	dense.pop_back();
	sparse[entity] = -1;
}

// ---------------------------------------------------------------------------
// ECSColumn — SoA 列存储 (Packed*Array, 零拷贝)
// ---------------------------------------------------------------------------

void ECSColumn::resize(size_t n) {
	switch (type) {
		case Variant::INT: i32.resize(int32_t(n)); break;
		case Variant::FLOAT: f32.resize(int32_t(n)); break;
		case Variant::BOOL: b.resize(int32_t(n)); break;
		case Variant::VECTOR2: v2.resize(int32_t(n)); break;
		case Variant::VECTOR3: v3.resize(int32_t(n)); break;
		case Variant::COLOR: col.resize(int32_t(n)); break;
		case Variant::STRING: s.resize(int32_t(n)); break;
		default: break;
	}
}

void ECSColumn::push_default(const Variant &value) {
	switch (type) {
		case Variant::INT: i32.push_back(int64_t(value)); break;
		case Variant::FLOAT: f32.push_back(double(value)); break;
		case Variant::BOOL: b.push_back(bool(value)); break;
		case Variant::VECTOR2: v2.push_back(Vector2(value)); break;
		case Variant::VECTOR3: v3.push_back(Vector3(value)); break;
		case Variant::COLOR: col.push_back(Color(value)); break;
		case Variant::STRING: s.push_back(String(value)); break;
		default: break;
	}
}

Variant ECSColumn::get(size_t row) const {
	switch (type) {
		case Variant::INT: return int64_t(i32[int32_t(row)]);
		case Variant::FLOAT: return double(f32[int32_t(row)]);
		case Variant::BOOL: return bool(b[int32_t(row)]);
		case Variant::VECTOR2: return v2[int32_t(row)];
		case Variant::VECTOR3: return v3[int32_t(row)];
		case Variant::COLOR: return col[int32_t(row)];
		case Variant::STRING: return s[int32_t(row)];
		default: return Variant();
	}
}

void ECSColumn::set(size_t row, const Variant &value) {
	const int32_t r = int32_t(row);
	switch (type) {
		case Variant::INT: i32[r] = int32_t(int64_t(value)); break;
		case Variant::FLOAT: f32[r] = float(double(value)); break;
		case Variant::BOOL: b[r] = uint8_t(bool(value)); break;
		case Variant::VECTOR2: v2[r] = Vector2(value); break;
		case Variant::VECTOR3: v3[r] = Vector3(value); break;
		case Variant::COLOR: col[r] = Color(value); break;
		case Variant::STRING: s[r] = String(value); break;
		default: break;
	}
}

size_t ECSColumn::size() const {
	switch (type) {
		case Variant::INT: return size_t(i32.size());
		case Variant::FLOAT: return size_t(f32.size());
		case Variant::BOOL: return size_t(b.size());
		case Variant::VECTOR2: return size_t(v2.size());
		case Variant::VECTOR3: return size_t(v3.size());
		case Variant::COLOR: return size_t(col.size());
		case Variant::STRING: return size_t(s.size());
		default: return 0;
	}
}

// ---------------------------------------------------------------------------
// ECSComponentData
// ---------------------------------------------------------------------------

int ECSComponentData::field_index(const StringName &f) const {
	for (size_t i = 0; i < fields.size(); ++i) {
		if (fields[i].name == f) {
			return int(i);
		}
	}
	return -1;
}

// ---------------------------------------------------------------------------
// ECSCore — 内部工具
// ---------------------------------------------------------------------------

ECSComponentData *ECSCore::find_comp(const StringName &name) {
	for (auto &c : components_) {
		if (c.name == name) {
			return &c;
		}
	}
	return nullptr;
}

const ECSComponentData *ECSCore::find_comp(const StringName &name) const {
	for (const auto &c : components_) {
		if (c.name == name) {
			return &c;
		}
	}
	return nullptr;
}

int32_t ECSCore::comp_index(const StringName &name) const {
	for (int32_t i = 0; i < int32_t(components_.size()); ++i) {
		if (components_[i].name == name) {
			return i;
		}
	}
	return -1;
}

// 签名聚簇索引: 相同组件集合共享一个签名组(用于 ID 分配)
int32_t ECSCore::sig_index_for(const std::vector<int32_t> &comps) {
	for (int32_t i = 0; i < int32_t(signatures_.size()); ++i) {
		if (signatures_[i].comps == comps) {
			return i;
		}
	}
	ECSSignature sig;
	sig.comps = comps;
	signatures_.push_back(std::move(sig));
	return int32_t(signatures_.size()) - 1;
}

int32_t ECSCore::allocate_entity_id() {
	// 优先复用空闲 ID(数值接近的复用, 保持聚簇)
	if (!free_list_.empty()) {
		int32_t index = free_list_.back();
		free_list_.pop_back();
		return index;
	}
	int32_t index = int32_t(versions_.size());
	versions_.push_back(0);
	return index;
}

void ECSCore::release_entity_id(int32_t index) {
	versions_[index]++;
	free_list_.push_back(index);
}

// ---------------------------------------------------------------------------
// ECSCore — 组件注册
// ---------------------------------------------------------------------------

int32_t ECSCore::register_component(const StringName &name, const PackedStringArray &fnames,
		const PackedInt32Array &ftypes, const Array &fdefaults) {
	if (find_comp(name) != nullptr) {
		return int32_t(components_.size()); // 已注册, 幂等
	}
	const int32_t n = int32_t(fnames.size());
	ECSComponentData data;
	data.name = name;
	data.fields.resize(n);
	data.columns.resize(n);
	data.defaults.resize(n);
	for (int32_t i = 0; i < n; ++i) {
		data.fields[i].name = fnames[i];
		data.fields[i].type = Variant::Type(int64_t(ftypes[i]));
		data.columns[i].type = data.fields[i].type;
		data.defaults[i] = (i < fdefaults.size()) ? fdefaults[i] : Variant();
	}
	components_.push_back(std::move(data));
	return int32_t(components_.size());
}

// ---------------------------------------------------------------------------
// ECSCore — 实体
// ---------------------------------------------------------------------------

int32_t ECSCore::create_entity() {
	int32_t index = allocate_entity_id();
	uint32_t version = versions_[index];
	return (int32_t(version) << 24) | index;
}

bool ECSCore::is_alive(int32_t entity) const {
	const int32_t index = entity & 0x00FFFFFF;
	const uint32_t version = uint32_t(entity >> 24) & 0xFF;
	if (index < 0 || index >= int32_t(versions_.size())) {
		return false;
	}
	return versions_[index] == version;
}

void ECSCore::destroy_entity(int32_t entity) {
	const int32_t index = entity & 0x00FFFFFF;
	if (index < 0 || index >= int32_t(versions_.size()) || !is_alive(entity)) {
		return;
	}
	// 从所有组件稀疏集中移除
	for (auto &c : components_) {
		if (c.set.has(index)) {
			c.set.remove(index);
		}
	}
	release_entity_id(index);
}

// ---------------------------------------------------------------------------
// ECSCore — 组件增删查
// ---------------------------------------------------------------------------

bool ECSCore::add_component(int32_t entity, const StringName &comp) {
	const int32_t index = entity & 0x00FFFFFF;
	ECSComponentData *c = find_comp(comp);
	if (c == nullptr || !is_alive(entity)) {
		return false;
	}
	const int32_t row = c->set.add(index);
	// 列按实体 ID 直接索引(稀疏): 保证跨组件对齐, query 返回的实体 ID 可索引任意列
	const int32_t need = index + 1;
	for (size_t fi = 0; fi < c->fields.size(); ++fi) {
		ECSColumn &col = c->columns[fi];
		if (col.size() < size_t(need)) {
			col.resize(size_t(need));
			col.set(index, c->defaults[fi]);
		}
	}
	return true;
}

bool ECSCore::has_component(int32_t entity, const StringName &comp) const {
	const int32_t index = entity & 0x00FFFFFF;
	const ECSComponentData *c = find_comp(comp);
	return c != nullptr && c->set.has(index);
}

void ECSCore::remove_component(int32_t entity, const StringName &comp) {
	const int32_t index = entity & 0x00FFFFFF;
	ECSComponentData *c = find_comp(comp);
	if (c == nullptr) {
		return;
	}
	c->set.remove(index);
}

int32_t ECSCore::count_entities(const StringName &comp) const {
	const ECSComponentData *c = find_comp(comp);
	return c ? int32_t(c->set.size()) : 0;
}

// ---------------------------------------------------------------------------
// ECSCore — 查询
// ---------------------------------------------------------------------------

PackedInt32Array ECSCore::query_rows(const StringName &anchor, const PackedStringArray &must,
		const PackedStringArray &without) const {
	PackedInt32Array out;
	const ECSComponentData *a = find_comp(anchor);
	if (a == nullptr || a->set.dense.empty()) {
		return out;
	}
	const int32_t m = int32_t(must.size());
	const int32_t w = int32_t(without.size());

	const ECSComponentData *req[8];
	const ECSComponentData *ban[8];
	if (m > 8 || w > 8) {
		return out;
	}
	for (int32_t i = 0; i < m; ++i) {
		req[i] = find_comp(must[i]);
	}
	for (int32_t i = 0; i < w; ++i) {
		ban[i] = find_comp(without[i]);
	}

	const auto &dense = a->set.dense;
	out.resize(int32_t(dense.size()));
	int32_t n = 0;
	for (int32_t r = 0; r < int32_t(dense.size()); ++r) {
		const int32_t e = dense[r];
		bool ok = true;
		for (int32_t i = 0; i < m; ++i) {
			if (req[i] == nullptr || !req[i]->set.has(e)) {
				ok = false;
				break;
			}
		}
		if (ok) {
			for (int32_t i = 0; i < w; ++i) {
				if (ban[i] != nullptr && ban[i]->set.has(e)) {
					ok = false;
					break;
				}
			}
		}
		if (ok) {
			out[n++] = e; // 实体 ID, 可直接索引任意组件列
		}
	}
	out.resize(n);
	return out;
}

int32_t ECSCore::entity_of_row(const StringName &comp, int32_t row) const {
	const ECSComponentData *c = find_comp(comp);
	if (c == nullptr || row < 0 || row >= int32_t(c->set.dense.size())) {
		return -1;
	}
	return c->set.dense[row];
}

// ---------------------------------------------------------------------------
// ECSCore — 单实体字段访问
// ---------------------------------------------------------------------------

Variant ECSCore::get_field(int32_t entity, const StringName &comp, const StringName &field) const {
	const int32_t index = entity & 0x00FFFFFF;
	const ECSComponentData *c = find_comp(comp);
	if (c == nullptr) {
		return Variant();
	}
	// 稀疏集只用于"该实体是否拥有此组件", 列按实体 ID 直接索引(稀疏)
	if (!c->set.has(index)) {
		return Variant();
	}
	const int fi = c->field_index(field);
	if (fi < 0) {
		return Variant();
	}
	return c->columns[fi].get(index);
}

void ECSCore::set_field(int32_t entity, const StringName &comp, const StringName &field, const Variant &value) {
	const int32_t index = entity & 0x00FFFFFF;
	ECSComponentData *c = find_comp(comp);
	if (c == nullptr) {
		return;
	}
	if (!c->set.has(index)) {
		return;
	}
	const int fi = c->field_index(field);
	if (fi < 0) {
		return;
	}
	c->columns[fi].set(index, value);
}

// ---------------------------------------------------------------------------
// ECSCore — 批量列访问 (零拷贝)
// ---------------------------------------------------------------------------

Variant ECSCore::get_column(const StringName &comp, const StringName &field) const {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return Variant();
	}
	const ECSComponentData &cd = components_[ci];
	const int fi = cd.field_index(field);
	if (fi < 0) {
		return Variant();
	}
	// 直接返回内部 Packed*Array 引用 —— 零拷贝, GDScript 共享同一内存
	const ECSColumn &col = cd.columns[fi];
	switch (col.type) {
		case Variant::INT: return col.i32;
		case Variant::FLOAT: return col.f32;
		case Variant::BOOL: return col.b;
		case Variant::VECTOR2: return col.v2;
		case Variant::VECTOR3: return col.v3;
		case Variant::COLOR: return col.col;
		case Variant::STRING: return col.s;
		default: return Variant();
	}
}

void ECSCore::set_column(const StringName &comp, const StringName &field, const Variant &values) {
	ECSComponentData *cd = find_comp(comp);
	if (cd == nullptr) {
		return;
	}
	const int fi = cd->field_index(field);
	if (fi < 0) {
		return;
	}
	// 引用赋值(指针交换): 无逐元素拷贝
	ECSColumn &col = cd->columns[fi];
	switch (col.type) {
		case Variant::INT: col.i32 = values; break;
		case Variant::FLOAT: col.f32 = values; break;
		case Variant::BOOL: col.b = values; break;
		case Variant::VECTOR2: col.v2 = values; break;
		case Variant::VECTOR3: col.v3 = values; break;
		case Variant::COLOR: col.col = values; break;
		case Variant::STRING: col.s = values; break;
		default: break;
	}
}

// ---------------------------------------------------------------------------
// ECSCore — Tier 0: 原生批量运算
// ---------------------------------------------------------------------------

// 收集 anchor dense 中满足 must 的实体(直接遍历 anchor 稀疏集)
static void collect_rows(const ECSComponentData *anchor, const ECSComponentData *const *req,
		int32_t m, std::vector<int32_t> &out) {
	out.clear();
	const auto &dense = anchor->set.dense;
	for (int32_t r = 0; r < int32_t(dense.size()); ++r) {
		const int32_t e = dense[r];
		bool ok = true;
		for (int32_t i = 0; i < m; ++i) {
			if (req[i] == nullptr || !req[i]->set.has(e)) {
				ok = false;
				break;
			}
		}
		if (ok) {
			out.push_back(e);
		}
	}
}

// ---------------------------------------------------------------------------
// 条件过滤: 解析 Array[Dictionary] 条件列表, 用于 batch_apply_where / batch_count
// 每个条件: {comp: StringName, field: StringName, op: int(CondOp), value: double}
// ---------------------------------------------------------------------------
namespace {

struct ECSFilterCond {
	const ECSComponentData *comp = nullptr;
	int field_idx = -1;
	int32_t op = 0;      // CondOp
	double value = 0.0;
};

// 解析条件列表, 返回有效条件数
int parse_conditions(const ECSCore *core, const Array &conds,
		std::vector<ECSFilterCond> &out, int max_conds) {
	out.clear();
	for (int i = 0; i < conds.size() && int(out.size()) < max_conds; ++i) {
		Dictionary d = conds[i];
		if (!d.has("comp") || !d.has("field")) {
			continue;
		}
		ECSFilterCond c;
		c.comp = core->find_comp(StringName(d["comp"]));
		if (c.comp == nullptr) {
			continue;
		}
		c.field_idx = c.comp->field_index(StringName(d["field"]));
		if (c.field_idx < 0) {
			continue;
		}
		c.op = int64_t(d.get("op", int64_t(0)));
		c.value = double(d.get("value", 0.0));
		out.push_back(c);
	}
	return int(out.size());
}

// 单实体是否满足所有条件(按列值比较)
inline bool cond_matches(const ECSCore *core, int32_t e, const std::vector<ECSFilterCond> &conds) {
	for (const auto &c : conds) {
		const ECSColumn &col = c.comp->columns[c.field_idx];
		double v = 0.0;
		switch (col.type) {
			case Variant::INT: v = double(col.i32[e]); break;
			case Variant::FLOAT: v = double(col.f32[e]); break;
			default: return false; // 条件仅支持数值字段
		}
		switch (c.op) {
			case ECSCore::COND_LT: if (!(v < c.value)) return false; break;
			case ECSCore::COND_LE: if (!(v <= c.value)) return false; break;
			case ECSCore::COND_GT: if (!(v > c.value)) return false; break;
			case ECSCore::COND_GE: if (!(v >= c.value)) return false; break;
			case ECSCore::COND_EQ: if (!(v == c.value)) return false; break;
			case ECSCore::COND_NE: if (!(v != c.value)) return false; break;
			default: return false;
		}
	}
	return true;
}

// 收集 anchor+must+条件 都满足的实体
void collect_rows_where(const ECSCore *core, const ECSComponentData *anchor,
		const ECSComponentData *const *req, int32_t m,
		const std::vector<ECSFilterCond> &conds, std::vector<int32_t> &out) {
	out.clear();
	const auto &dense = anchor->set.dense;
	for (int32_t r = 0; r < int32_t(dense.size()); ++r) {
		const int32_t e = dense[r];
		bool ok = true;
		for (int32_t i = 0; i < m; ++i) {
			if (req[i] == nullptr || !req[i]->set.has(e)) {
				ok = false;
				break;
			}
		}
		if (ok && cond_matches(core, e, conds)) {
			out.push_back(e);
		}
	}
}

} // namespace

int64_t ECSCore::batch_count(const StringName &anchor, const PackedStringArray &must,
		const Array &conditions) const {
	const ECSComponentData *a = find_comp(anchor);
	if (a == nullptr) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	std::vector<ECSFilterCond> conds;
	parse_conditions(this, conditions, conds, 8);
	std::vector<int32_t> rows;
	collect_rows_where(this, a, req, m > 8 ? 8 : m, conds, rows);
	return int64_t(rows.size());
}

int64_t ECSCore::batch_apply_where(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field, int64_t op,
		double factor, double addend, const Array &conditions) {
	ECSComponentData *a = find_comp(anchor);
	ECSComponentData *oc = find_comp(op_comp);
	if (a == nullptr || oc == nullptr) {
		return 0;
	}
	const int fi = oc->field_index(op_field);
	if (fi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	std::vector<ECSFilterCond> conds;
	parse_conditions(this, conditions, conds, 8);
	std::vector<int32_t> rows;
	collect_rows_where(this, a, req, m > 8 ? 8 : m, conds, rows);

	ECSColumn &col = oc->columns[fi];
	int64_t n = 0;
	switch (col.type) {
		case Variant::INT: {
			int32_t *w = col.i32.ptrw();
			const int32_t add = int32_t(addend);
			for (int32_t e : rows) {
				switch (op) {
					case BATCH_ADD: w[e] += add; break;
					case BATCH_MUL_ADD: w[e] = int32_t(double(w[e]) * factor + addend); break;
					case BATCH_SET: w[e] = add; break;
					default: break;
				}
				++n;
			}
			break;
		}
		case Variant::FLOAT: {
			float *w = col.f32.ptrw();
			for (int32_t e : rows) {
				switch (op) {
					case BATCH_ADD: w[e] += float(addend); break;
					case BATCH_MUL_ADD: w[e] = float(double(w[e]) * factor + addend); break;
					case BATCH_SET: w[e] = float(addend); break;
					default: break;
				}
				++n;
			}
			break;
		}
		default:
			break;
	}
	return n;
}

int64_t ECSCore::batch_apply(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field, int64_t op,
		double factor, double addend) {
	ECSComponentData *a = find_comp(anchor);
	ECSComponentData *oc = find_comp(op_comp);
	if (a == nullptr || oc == nullptr) {
		return 0;
	}
	const int fi = oc->field_index(op_field);
	if (fi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	std::vector<int32_t> rows;
	collect_rows(a, req, m > 8 ? 8 : m, rows);

	ECSColumn &col = oc->columns[fi];
	int64_t n = 0;
	switch (col.type) {
		case Variant::INT: {
			int32_t *w = col.i32.ptrw();
			const int32_t add = int32_t(addend);
			for (int32_t e : rows) {
				switch (op) {
					case BATCH_ADD: w[e] += add; break;
					case BATCH_MUL_ADD: w[e] = int32_t(double(w[e]) * factor + addend); break;
					case BATCH_SET: w[e] = add; break;
					default: break;
				}
				++n;
			}
			break;
		}
		case Variant::FLOAT: {
			float *w = col.f32.ptrw();
			for (int32_t e : rows) {
				switch (op) {
					case BATCH_ADD: w[e] += float(addend); break;
					case BATCH_MUL_ADD: w[e] = float(double(w[e]) * factor + addend); break;
					case BATCH_SET: w[e] = float(addend); break;
					default: break;
				}
				++n;
			}
			break;
		}
		default:
			break;
	}
	return n;
}

int64_t ECSCore::batch_clamp(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field,
		const StringName &min_comp, const StringName &min_field,
		const StringName &max_comp, const StringName &max_field) {
	ECSComponentData *a = find_comp(anchor);
	ECSComponentData *oc = find_comp(op_comp);
	ECSComponentData *minc = find_comp(min_comp);
	ECSComponentData *maxc = find_comp(max_comp);
	if (a == nullptr || oc == nullptr || minc == nullptr || maxc == nullptr) {
		return 0;
	}
	const int fi = oc->field_index(op_field);
	const int mini = minc->field_index(min_field);
	const int maxi = maxc->field_index(max_field);
	if (fi < 0 || mini < 0 || maxi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	std::vector<int32_t> rows;
	collect_rows(a, req, m > 8 ? 8 : m, rows);

	ECSColumn &col = oc->columns[fi];
	const ECSColumn &mincol = minc->columns[mini];
	const ECSColumn &maxcol = maxc->columns[maxi];
	int64_t n = 0;
	switch (col.type) {
		case Variant::INT: {
			int32_t *w = col.i32.ptrw();
			const int32_t *mn = mincol.i32.ptr();
			const int32_t *mx = maxcol.i32.ptr();
			for (int32_t e : rows) {
				w[e] = CLAMP(w[e], mn[e], mx[e]);
				++n;
			}
			break;
		}
		case Variant::FLOAT: {
			float *w = col.f32.ptrw();
			const float *mn = mincol.f32.ptr();
			const float *mx = maxcol.f32.ptr();
			for (int32_t e : rows) {
				w[e] = CLAMP(w[e], mn[e], mx[e]);
				++n;
			}
			break;
		}
		default:
			break;
	}
	return n;
}

int64_t ECSCore::batch_vec_add(const StringName &anchor, const PackedStringArray &must,
		const StringName &pos_comp, const StringName &pos_field,
		const StringName &vel_comp, const StringName &vel_field, double delta) {
	ECSComponentData *a = find_comp(anchor);
	ECSComponentData *posc = find_comp(pos_comp);
	ECSComponentData *velc = find_comp(vel_comp);
	if (a == nullptr || posc == nullptr || velc == nullptr) {
		return 0;
	}
	const int pfi = posc->field_index(pos_field);
	const int vfi = velc->field_index(vel_field);
	if (pfi < 0 || vfi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	std::vector<int32_t> rows;
	collect_rows(a, req, m > 8 ? 8 : m, rows);

	ECSColumn &poscol = posc->columns[pfi];
	const ECSColumn &velcol = velc->columns[vfi];
	int64_t n = 0;
	if (poscol.type == Variant::VECTOR2 && velcol.type == Variant::VECTOR2) {
		Vector2 *p = poscol.v2.ptrw();
		const Vector2 *v = velcol.v2.ptr();
		const float d = float(delta);
		for (int32_t e : rows) {
			p[e] += v[e] * d;
			++n;
		}
	} else if (poscol.type == Variant::VECTOR3 && velcol.type == Variant::VECTOR3) {
		Vector3 *p = poscol.v3.ptrw();
		const Vector3 *v = velcol.v3.ptr();
		const float d = float(delta);
		for (int32_t e : rows) {
			p[e] += v[e] * d;
			++n;
		}
	}
	return n;
}

// ---------------------------------------------------------------------------
// ECSCore — 调试统计
// ---------------------------------------------------------------------------

Dictionary ECSCore::debug_stats() const {
	Dictionary d;
	d["components"] = int64_t(components_.size());
	d["entity_pool"] = int64_t(versions_.size());
	Array comp_counts;
	for (const auto &c : components_) {
		comp_counts.append(int64_t(c.set.size()));
	}
	d["component_counts"] = comp_counts;
	return d;
}

// ---------------------------------------------------------------------------
// ECSCore — 序列化/反序列化
// ---------------------------------------------------------------------------

Dictionary ECSCore::serialize() const {
	Dictionary root;
	root["version"] = int64_t(1);
	Array comps;
	for (const auto &c : components_) {
		Dictionary cd;
		cd["name"] = c.name;
		// 字段描述
		Array farr;
		Array fnames_arr;
		Array ftypes_arr;
		Array fdefaults_arr;
		for (size_t fi = 0; fi < c.fields.size(); ++fi) {
			fnames_arr.append(c.fields[fi].name);
			ftypes_arr.append(int64_t(c.fields[fi].type));
			fdefaults_arr.append(c.defaults[fi]);
		}
		cd["field_names"] = fnames_arr;
		cd["field_types"] = ftypes_arr;
		cd["defaults"] = fdefaults_arr;
		// 实体数据: 稀疏集 dense 里的实体 + 各字段值
		// 注意: 列按"实体 ID"索引(稀疏), 必须用实体 ID e 取值, 而非行号 r!
		Array entities;
		const auto &dense = c.set.dense;
		for (int32_t r = 0; r < int32_t(dense.size()); ++r) {
			const int32_t e = dense[r];
			Dictionary ed;
			ed["entity"] = e;
			Array vals;
			for (size_t fi = 0; fi < c.columns.size(); ++fi) {
				vals.append(c.columns[fi].get(e));
			}
			ed["values"] = vals;
			entities.append(ed);
		}
		cd["entities"] = entities;
		comps.append(cd);
	}
	root["components"] = comps;
	root["pool_size"] = int64_t(versions_.size());
	return root;
}

Array ECSCore::deserialize(const Dictionary &data) {
	Array result; // 新建实体的实体 ID 列表
	if (!data.has("components")) {
		return result;
	}
	// 第一遍: 收集所有需要创建的实体 ID 集合(按出现顺序)
	std::vector<int32_t> entity_ids;
	{
		Array comps = data["components"];
		for (int32_t i = 0; i < comps.size(); ++i) {
			Dictionary cd = comps[i];
			Array entities = cd["entities"];
			for (int32_t j = 0; j < entities.size(); ++j) {
				Dictionary ed = entities[j];
				const int32_t saved_id = int32_t(int64_t(ed["entity"]));
				bool seen = false;
				for (int32_t e : entity_ids) {
					if (e == saved_id) {
						seen = true;
						break;
					}
				}
				if (!seen) {
					entity_ids.push_back(saved_id);
				}
			}
		}
	}
	// 建立 存档ID -> 新实体ID 映射, 并创建实体
	std::unordered_map<int32_t, int32_t> id_map;
	id_map.reserve(entity_ids.size());
	for (int32_t saved_id : entity_ids) {
		const int32_t new_id = create_entity();
		id_map[saved_id] = new_id;
		result.append(new_id); // 返回真实实体 ID
	}

	// 第二遍: 填充组件数据
	Array comps = data["components"];
	for (int32_t i = 0; i < comps.size(); ++i) {
		Dictionary cd = comps[i];
		const StringName name = cd["name"];
		ECSComponentData *c = find_comp(name);
		if (c == nullptr) {
			continue;
		}
		Array entities = cd["entities"];
		for (int32_t j = 0; j < entities.size(); ++j) {
			Dictionary ed = entities[j];
			const int32_t saved_id = int32_t(int64_t(ed["entity"]));
			auto it = id_map.find(saved_id);
			if (it == id_map.end()) {
				continue;
			}
			const int32_t index = it->second & 0x00FFFFFF;
			c->set.add(index);
			const int32_t need = index + 1;
			for (size_t fi = 0; fi < c->columns.size(); ++fi) {
				ECSColumn &col = c->columns[fi];
				if (col.size() < size_t(need)) {
					col.resize(size_t(need));
				}
			}
			Array vals = ed["values"];
			const int32_t nv = int32_t(vals.size());
			for (int32_t fi = 0; fi < int32_t(c->columns.size()); ++fi) {
				if (fi < nv) {
					c->columns[fi].set(index, vals[fi]);
				} else {
					c->columns[fi].set(index, c->defaults[fi]);
				}
			}
		}
	}
	return result;
}

// ---------------------------------------------------------------------------
// ECSCore — 绑定
// ---------------------------------------------------------------------------

void ECSCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("register_component", "name", "fnames", "ftypes", "fdefaults"), &ECSCore::register_component);
	ClassDB::bind_method(D_METHOD("create_entity"), &ECSCore::create_entity);
	ClassDB::bind_method(D_METHOD("is_alive", "entity"), &ECSCore::is_alive);
	ClassDB::bind_method(D_METHOD("destroy_entity", "entity"), &ECSCore::destroy_entity);
	ClassDB::bind_method(D_METHOD("add_component", "entity", "comp"), &ECSCore::add_component);
	ClassDB::bind_method(D_METHOD("has_component", "entity", "comp"), &ECSCore::has_component);
	ClassDB::bind_method(D_METHOD("remove_component", "entity", "comp"), &ECSCore::remove_component);
	ClassDB::bind_method(D_METHOD("count_entities", "comp"), &ECSCore::count_entities);
	ClassDB::bind_method(D_METHOD("query_rows", "anchor", "must", "without"), &ECSCore::query_rows);
	ClassDB::bind_method(D_METHOD("entity_of_row", "comp", "row"), &ECSCore::entity_of_row);
	ClassDB::bind_method(D_METHOD("get_field", "entity", "comp", "field"), &ECSCore::get_field);
	ClassDB::bind_method(D_METHOD("set_field", "entity", "comp", "field", "value"), &ECSCore::set_field);
	ClassDB::bind_method(D_METHOD("get_column", "comp", "field"), &ECSCore::get_column);
	ClassDB::bind_method(D_METHOD("set_column", "comp", "field", "values"), &ECSCore::set_column);
	ClassDB::bind_method(D_METHOD("batch_apply", "anchor", "must", "op_comp", "op_field", "op", "factor", "addend"), &ECSCore::batch_apply);
	ClassDB::bind_method(D_METHOD("batch_apply_where", "anchor", "must", "op_comp", "op_field", "op", "factor", "addend", "conditions"), &ECSCore::batch_apply_where);
	ClassDB::bind_method(D_METHOD("batch_count", "anchor", "must", "conditions"), &ECSCore::batch_count);
	ClassDB::bind_method(D_METHOD("batch_clamp", "anchor", "must", "op_comp", "op_field", "min_comp", "min_field", "max_comp", "max_field"), &ECSCore::batch_clamp);
	ClassDB::bind_method(D_METHOD("batch_vec_add", "anchor", "must", "pos_comp", "pos_field", "vel_comp", "vel_field", "delta"), &ECSCore::batch_vec_add);
	ClassDB::bind_method(D_METHOD("debug_stats"), &ECSCore::debug_stats);
	ClassDB::bind_method(D_METHOD("serialize"), &ECSCore::serialize);
	ClassDB::bind_method(D_METHOD("deserialize", "data"), &ECSCore::deserialize);
}
