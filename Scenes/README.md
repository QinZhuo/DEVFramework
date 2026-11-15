# 场景索引

框架自带的可运行示例都在这里。**每个目录对应一个能力模块**，`*Demo.tscn` 是可以直接按 F6 运行的演示，
其余是演示所用的子场景（不可单独运行）。

> 运行方式：在编辑器中打开场景后按 F6；或命令行
> `godot --path . Scenes/<模块>/<名字>Demo.tscn`
> 也可以用 MCP：`game_control(action=start, scene="res://Scenes/...")`

## 演示场景

| 场景 | 演示什么 | 操作要点 |
|---|---|---|
| `AI/GoapDemo.tscn` | GOAP 目标规划（Goal / Action / Planner） | 观察代理自主选择动作顺序 |
| `Dialogue/DialogueDemo.tscn` | **对话子系统**：单行提示、多行脚本、锚点跟随、插槽、定位策略 | 拖动「拖我」方块看气泡跟随并自动翻转；按钮切换插槽/贴底/左上角 |
| `ECS/ECSDemo.tscn` | ECS 世界、组件、系统调度 | 观察实体按系统批量更新 |
| `ECS/ECSNodeDemo.tscn` | ECS 与场景节点同步（点云示例） | 组件改动实时反映到节点 |
| `GameCommand/GameCommandDemo.tscn` | 命令模式 + 输入源（可回放） | 操作后重放，命令历史逐步复现 |
| `Lightmap/LightmapDemo.tscn` | 光照贴图烘焙结果 | 对比烘焙/未烘焙的明暗 |
| `Nav/NavPlayer.tscn` | 导航：玩家 + 障碍 + 巡逻 NPC | 点击地面移动，观察绕障与巡逻 |
| `Tutorial/TutorialDemo.tscn` | **教程引导**：遮罩聚焦、气泡、步骤推进 | 按提示点击；ESC 退出教程 |
| `View/PoolDemo.tscn` | 对象池复用（列表滚动） | 滚动列表观察实例复用不新建 |
| `View/PoolDemoCard.tscn` | 对象池 + 卡片项 | 同上，卡片形态 |

## 工具场景（不是演示，按需运行）

| 场景 | 用途 |
|---|---|
| `Lightmap/LightmapBake.tscn` | 批量烘焙光照贴图 |
| `ECS/impl_query.tscn` | ECS 查询实现细节验证 |
| `Nav/NavObstacle.tscn` / `NavPatrolNPC.tscn` | `NavPlayer` 引用的子场景 |

## 命名约定

- 目录 = 能力模块名（与 `addons/DEVFramework/` 下的模块同名）
- `*Demo.tscn` = **可直接运行的演示**
- 其他 `.tscn` = 演示用的子场景 / 工具场景
- 演示脚本与场景**同目录**（`Scenes/<模块>/<名字>Demo.gd`）；演示用的示例业务对象放 `res://Scripts/Entity/`

## 新增演示时

1. 场景放 `Scenes/<模块>/<名字>Demo.tscn`
2. 脚本与场景同目录：`Scenes/<模块>/<名字>Demo.gd`
3. 在本文件「演示场景」表格里补一行（说明演示什么 + 怎么操作）

这样任何人不用翻目录就能知道框架有哪些能力、怎么跑起来。
