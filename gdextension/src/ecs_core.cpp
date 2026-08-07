#include "ecs_core.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>

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
// ECSColumn — SoA 列存储
// ---------------------------------------------------------------------------

void ECSColumn::resize(size_t n) {
	switch (type) {
		case Variant::INT: i32.resize(n); break;
		case Variant::FLOAT: f32.resize(n); break;
		case Variant::BOOL: b.resize(n); break;
		case Variant::VECTOR2: v2.resize(n); break;
		case Variant::VECTOR3: v3.resize(n); break;
		case Variant::COLOR: col.resize(n); break;
		case Variant::STRING: s.resize(n); break;
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
		case Variant::INT: return int64_t(i32[row]);
		case Variant::FLOAT: return double(f32[row]);
		case Variant::BOOL: return bool(b[row]);
		case Variant::VECTOR2: return v2[row];
		case Variant::VECTOR3: return v3[row];
		case Variant::COLOR: return col[row];
		case Variant::STRING: return s[row];
		default: return Variant();
	}
}

void ECSColumn::set(size_t row, const Variant &value) {
	switch (type) {
		case Variant::INT: i32[row] = int32_t(int64_t(value)); break;
		case Variant::FLOAT: f32[row] = float(double(value)); break;
		case Variant::BOOL: b[row] = uint8_t(bool(value)); break;
		case Variant::VECTOR2: v2[row] = Vector2(value); break;
		case Variant::VECTOR3: v3[row] = Vector3(value); break;
		case Variant::COLOR: col[row] = Color(value); break;
		case Variant::STRING: s[row] = String(value); break;
		default: break;
	}
}

size_t ECSColumn::size() const {
	switch (type) {
		case Variant::INT: return i32.size();
		case Variant::FLOAT: return f32.size();
		case Variant::BOOL: return b.size();
		case Variant::VECTOR2: return v2.size();
		case Variant::VECTOR3: return v3.size();
		case Variant::COLOR: return col.size();
		case Variant::STRING: return s.size();
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
// ECSCore
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

int32_t ECSCore::register_component(const StringName &name, const PackedStringArray &fnames,
		const PackedInt32Array &ftypes, const Array &fdefaults) {
	if (find_comp(name) != nullptr) {
		return 0; // 已注册, 幂等
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

int32_t ECSCore::create_entity() {
	int32_t index;
	uint32_t version;
	if (!free_list_.empty()) {
		index = free_list_.back();
		free_list_.pop_back();
		version = versions_[index];
	} else {
		index = int32_t(versions_.size());
		versions_.push_back(0);
		version = 0;
	}
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
	if (index < 0 || index >= int32_t(versions_.size())) {
		return;
	}
	// 从所有组件稀疏集中移除
	for (auto &c : components_) {
		if (c.set.has(index)) {
			c.set.remove(index);
		}
	}
	versions_[index]++;
	free_list_.push_back(index);
}

bool ECSCore::add_component(int32_t entity, const StringName &comp) {
	const int32_t index = entity & 0x00FFFFFF;
	ECSComponentData *c = find_comp(comp);
	if (c == nullptr || !is_alive(entity)) {
		return false;
	}
	const int32_t row = c->set.add(index);
	// 列按"实体 ID 直接索引"(稀疏列): 所有组件共享同一实体 ID 索引空间,
	// 保证 query 返回的实体 ID 可同时索引任意组件的列(跨组件对齐)。
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

PackedInt32Array ECSCore::query_rows(const StringName &anchor, const PackedStringArray &must,
		const PackedStringArray &without) const {
	PackedInt32Array out;
	const ECSComponentData *a = find_comp(anchor);
	if (a == nullptr || a->set.dense.empty()) {
		return out;
	}
	const int32_t m = int32_t(must.size());
	const int32_t w = int32_t(without.size());

	// 预取 must/without 的稀疏集引用
	const ECSComponentData *req[8];
	const ECSComponentData *ban[8];
	if (m > 8 || w > 8) {
		return out; // 超出简单场景上限
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
			out[n++] = e; // 返回实体 ID, 可直接索引任意组件列
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

Variant ECSCore::get_field(int32_t entity, const StringName &comp, const StringName &field) const {
	const int32_t index = entity & 0x00FFFFFF;
	const ECSComponentData *c = find_comp(comp);
	if (c == nullptr) {
		return Variant();
	}
	const int32_t row = c->set.row_of(index);
	if (row < 0) {
		return Variant();
	}
	const int fi = c->field_index(field);
	if (fi < 0) {
		return Variant();
	}
	return c->columns[fi].get(row);
}

void ECSCore::set_field(int32_t entity, const StringName &comp, const StringName &field, const Variant &value) {
	const int32_t index = entity & 0x00FFFFFF;
	ECSComponentData *c = find_comp(comp);
	if (c == nullptr) {
		return;
	}
	const int32_t row = c->set.row_of(index);
	if (row < 0) {
		return;
	}
	const int fi = c->field_index(field);
	if (fi < 0) {
		return;
	}
	c->columns[fi].set(row, value);
}

Variant ECSCore::get_column(const StringName &comp, const StringName &field) const {
	const ECSComponentData *c = find_comp(comp);
	if (c == nullptr) {
		return Variant();
	}
	const int fi = c->field_index(field);
	if (fi < 0) {
		return Variant();
	}
	const ECSColumn &col = c->columns[fi];
	const size_t n = col.size();
	switch (col.type) {
		case Variant::INT: {
			PackedInt32Array arr;
			arr.resize(int32_t(n));
			int32_t *w = arr.ptrw();
			for (size_t i = 0; i < n; ++i) w[i] = col.i32[i];
			return arr;
		}
		case Variant::FLOAT: {
			PackedFloat32Array arr;
			arr.resize(int32_t(n));
			float *w = arr.ptrw();
			for (size_t i = 0; i < n; ++i) w[i] = col.f32[i];
			return arr;
		}
		case Variant::BOOL: {
			PackedByteArray arr;
			arr.resize(int32_t(n));
			uint8_t *w = arr.ptrw();
			for (size_t i = 0; i < n; ++i) w[i] = col.b[i];
			return arr;
		}
		case Variant::VECTOR2: {
			PackedVector2Array arr;
			arr.resize(int32_t(n));
			Vector2 *w = arr.ptrw();
			for (size_t i = 0; i < n; ++i) w[i] = col.v2[i];
			return arr;
		}
		case Variant::VECTOR3: {
			PackedVector3Array arr;
			arr.resize(int32_t(n));
			Vector3 *w = arr.ptrw();
			for (size_t i = 0; i < n; ++i) w[i] = col.v3[i];
			return arr;
		}
		case Variant::COLOR: {
			PackedColorArray arr;
			arr.resize(int32_t(n));
			Color *w = arr.ptrw();
			for (size_t i = 0; i < n; ++i) w[i] = col.col[i];
			return arr;
		}
		case Variant::STRING: {
			PackedStringArray arr;
			arr.resize(int32_t(n));
			for (size_t i = 0; i < n; ++i) arr[i] = col.s[i];
			return arr;
		}
		default:
			return Variant();
	}
}

void ECSCore::set_column(const StringName &comp, const StringName &field, const Variant &values) {
	ECSComponentData *c = find_comp(comp);
	if (c == nullptr) {
		return;
	}
	const int fi = c->field_index(field);
	if (fi < 0) {
		return;
	}
	ECSColumn &col = c->columns[fi];
	switch (col.type) {
		case Variant::INT: {
			const PackedInt32Array arr = values;
			const int32_t n = int32_t(arr.size());
			col.i32.resize(n);
			const int32_t *r = arr.ptr();
			for (int32_t i = 0; i < n; ++i) col.i32[i] = r[i];
			break;
		}
		case Variant::FLOAT: {
			const PackedFloat32Array arr = values;
			const int32_t n = int32_t(arr.size());
			col.f32.resize(n);
			const float *r = arr.ptr();
			for (int32_t i = 0; i < n; ++i) col.f32[i] = r[i];
			break;
		}
		case Variant::BOOL: {
			const PackedByteArray arr = values;
			const int32_t n = int32_t(arr.size());
			col.b.resize(n);
			const uint8_t *r = arr.ptr();
			for (int32_t i = 0; i < n; ++i) col.b[i] = r[i];
			break;
		}
		case Variant::VECTOR2: {
			const PackedVector2Array arr = values;
			const int32_t n = int32_t(arr.size());
			col.v2.resize(n);
			const Vector2 *r = arr.ptr();
			for (int32_t i = 0; i < n; ++i) col.v2[i] = r[i];
			break;
		}
		case Variant::VECTOR3: {
			const PackedVector3Array arr = values;
			const int32_t n = int32_t(arr.size());
			col.v3.resize(n);
			const Vector3 *r = arr.ptr();
			for (int32_t i = 0; i < n; ++i) col.v3[i] = r[i];
			break;
		}
		case Variant::COLOR: {
			const PackedColorArray arr = values;
			const int32_t n = int32_t(arr.size());
			col.col.resize(n);
			const Color *r = arr.ptr();
			for (int32_t i = 0; i < n; ++i) col.col[i] = r[i];
			break;
		}
		case Variant::STRING: {
			const PackedStringArray arr = values;
			const int32_t n = int32_t(arr.size());
			col.s.resize(n);
			for (int32_t i = 0; i < n; ++i) col.s[i] = arr[i];
			break;
		}
		default:
			break;
	}
}

// ---------------------------------------------------------------------------
// Tier 0: 原生批量运算 (纯 C++ 循环, 无 GDScript 解释开销)
// ---------------------------------------------------------------------------

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
	ECSColumn &col = oc->columns[fi];
	const int m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	int64_t n_processed = 0;
	switch (col.type) {
		case Variant::INT: {
			for (int32_t r = 0; r < int32_t(a->set.dense.size()); ++r) {
				const int32_t e = a->set.dense[r];
				bool ok = true;
				for (int32_t i = 0; i < m && i < 8; ++i) {
					if (req[i] == nullptr || !req[i]->set.has(e)) {
						ok = false;
						break;
					}
				}
				if (!ok || e >= int32_t(col.i32.size())) {
					continue;
				}
				int32_t v = col.i32[e];
				switch (op) {
					case BATCH_ADD: v += int32_t(addend); break;
					case BATCH_MUL_ADD: v = int32_t(double(v) * factor + addend); break;
					case BATCH_SET: v = int32_t(addend); break;
					case BATCH_CLAMP: break;
				}
				col.i32[e] = v;
				++n_processed;
			}
			break;
		}
		case Variant::FLOAT: {
			for (int32_t r = 0; r < int32_t(a->set.dense.size()); ++r) {
				const int32_t e = a->set.dense[r];
				bool ok = true;
				for (int32_t i = 0; i < m && i < 8; ++i) {
					if (req[i] == nullptr || !req[i]->set.has(e)) {
						ok = false;
						break;
					}
				}
				if (!ok || e >= int32_t(col.f32.size())) {
					continue;
				}
				float v = col.f32[e];
				switch (op) {
					case BATCH_ADD: v += float(addend); break;
					case BATCH_MUL_ADD: v = float(double(v) * factor + addend); break;
					case BATCH_SET: v = float(addend); break;
					case BATCH_CLAMP: break;
				}
				col.f32[e] = v;
				++n_processed;
			}
			break;
		}
		default:
			break;
	}
	return n_processed;
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
	ECSColumn &col = oc->columns[fi];
	const ECSColumn &mincol = minc->columns[mini];
	const ECSColumn &maxcol = maxc->columns[maxi];
	const int m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	int64_t n_processed = 0;
	switch (col.type) {
		case Variant::INT: {
			for (int32_t r = 0; r < int32_t(a->set.dense.size()); ++r) {
				const int32_t e = a->set.dense[r];
				bool ok = true;
				for (int32_t i = 0; i < m && i < 8; ++i) {
					if (req[i] == nullptr || !req[i]->set.has(e)) {
						ok = false;
						break;
					}
				}
				if (!ok || e >= int32_t(col.i32.size()) || e >= int32_t(mincol.i32.size()) || e >= int32_t(maxcol.i32.size())) {
					continue;
				}
				col.i32[e] = CLAMP(col.i32[e], mincol.i32[e], maxcol.i32[e]);
				++n_processed;
			}
			break;
		}
		case Variant::FLOAT: {
			for (int32_t r = 0; r < int32_t(a->set.dense.size()); ++r) {
				const int32_t e = a->set.dense[r];
				bool ok = true;
				for (int32_t i = 0; i < m && i < 8; ++i) {
					if (req[i] == nullptr || !req[i]->set.has(e)) {
						ok = false;
						break;
					}
				}
				if (!ok || e >= int32_t(col.f32.size()) || e >= int32_t(mincol.f32.size()) || e >= int32_t(maxcol.f32.size())) {
					continue;
				}
				col.f32[e] = CLAMP(col.f32[e], mincol.f32[e], maxcol.f32[e]);
				++n_processed;
			}
			break;
		}
		default:
			break;
	}
	return n_processed;
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
	ECSColumn &poscol = posc->columns[pfi];
	const ECSColumn &velcol = velc->columns[vfi];
	const int m = int32_t(must.size());
	const ECSComponentData *req[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		req[i] = find_comp(must[i]);
	}
	int64_t n_processed = 0;
	if (poscol.type == Variant::VECTOR2 && velcol.type == Variant::VECTOR2) {
		for (int32_t r = 0; r < int32_t(a->set.dense.size()); ++r) {
			const int32_t e = a->set.dense[r];
			bool ok = true;
			for (int32_t i = 0; i < m && i < 8; ++i) {
				if (req[i] == nullptr || !req[i]->set.has(e)) {
					ok = false;
					break;
				}
			}
			if (!ok || e >= int32_t(poscol.v2.size()) || e >= int32_t(velcol.v2.size())) {
				continue;
			}
			poscol.v2[e] += velcol.v2[e] * float(delta);
			++n_processed;
		}
	} else if (poscol.type == Variant::VECTOR3 && velcol.type == Variant::VECTOR3) {
		for (int32_t r = 0; r < int32_t(a->set.dense.size()); ++r) {
			const int32_t e = a->set.dense[r];
			bool ok = true;
			for (int32_t i = 0; i < m && i < 8; ++i) {
				if (req[i] == nullptr || !req[i]->set.has(e)) {
					ok = false;
					break;
				}
			}
			if (!ok || e >= int32_t(poscol.v3.size()) || e >= int32_t(velcol.v3.size())) {
				continue;
			}
			poscol.v3[e] += velcol.v3[e] * float(delta);
			++n_processed;
		}
	}
	return n_processed;
}

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
	ClassDB::bind_method(D_METHOD("batch_clamp", "anchor", "must", "op_comp", "op_field", "min_comp", "min_field", "max_comp", "max_field"), &ECSCore::batch_clamp);
	ClassDB::bind_method(D_METHOD("batch_vec_add", "anchor", "must", "pos_comp", "pos_field", "vel_comp", "vel_field", "delta"), &ECSCore::batch_vec_add);
}
