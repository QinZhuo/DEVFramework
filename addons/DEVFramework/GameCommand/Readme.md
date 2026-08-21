# GameCommand 模块

"命令即数据"：把一次玩家/AI 决策记录为可序列化的数据单元，用于回放、战绩审计与 headless 自动化测试。

## 组成

| 类 | 职责 |
|---|---|
| `GameCommand` | 一条命令记录：`action`(StringName 类型名) + `tick`(时序序号，回合制下即回合号) + `params`(决策参数数组) |
| `CommandHistory` | 按序记录命令；按 tick 过滤/弹出；整体序列化 |
| `InputSource` | 决策输入策略基类。模拟层通过 `take(request) -> int` 获取决策，不感知来源是 UI、回放还是脚本 |
| `ReplayInputSource` | 回放输入源：按序弹出预录决策（`answers`），并记录已消费的 `journal` 供校验 |

## 典型流程

1. 实战时：模拟层通过真实 UI 的 InputSource 获取决策 → 成功后构造 `GameCommand` 写入 `CommandHistory`
2. 存档：`history.save_data()` 得到纯 Array，可随存档保存
3. 回放/测试：`GameCommand.load_data()` 还原 → 把 params 决策段喂给 `ReplayInputSource.answers` → 重放模拟，结束时比对 journal 与 answers 确定一致

## 示例

```gdscript
# 记录
var history := CommandHistory.new()
history.append(GameCommand.new(&"pick_column", tick, [3]))
var data: Array = history.save_data()

# 回放
var replay := ReplayInputSource.new([3])
var value := replay.take({})   # -> 3
assert(replay.journal == [3])
```

## 约定

- `InputSource.take()` 返回 `-1` 表示取消/无输入
- `params[0]` 惯例为动作主体标识
- 同一命令序列 + 相同初始状态 ⇒ 必须复现相同结果（确定性回放）
