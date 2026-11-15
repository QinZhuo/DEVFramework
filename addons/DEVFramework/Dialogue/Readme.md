# Dialogue —— 通用对话 / 提示子系统

与 `AI/`、`Camera/` 同构：**Def（数据）/ Entity（运行时）/ View（表现）/ Tool（入口）**。
框架只提供结构与能力，**长什么样由项目决定**。

```
Dialogue/
├─ Def/DialogueLineDef.gd      一行对话（说话人 / 文本 key / 立绘 / 标签 / 自动推进时长）
├─ Def/DialogueScriptDef.gd    一段对话（行数组 + loop / 可否跳过 / 是否锁输入）
├─ Entity/DialogueSession.gd   运行实例（游标 + 推进 + started/line_changed/finished/cancelled）
├─ View/DialoguePresenter.gd   表现基类（只定义能力：present/dismiss/refresh/attach_slot + 定位策略）
├─ View/BubblePresenter.gd     默认实现（一条圆角气泡；可替换）
└─ Tool/DialogueTool.gd        静态入口（bind / show_text / play / advance / stop）
```

## 三层职责

| 层 | 管什么 | 不管什么 |
|---|---|---|
| `DialogueScriptDef` / `DialogueLineDef` | 说什么（数据、翻译 key） | 怎么显示 |
| `DialogueSession` | 播到第几行、何时结束（只发信号） | 任何 UI |
| `DialoguePresenter` | 显示成什么样、摆哪里 | 播放顺序 |

## 用法

```gdscript
# 1) 绑定表现层（通常由遮罩在 _ready 里做；也可以自己调）
DialogueTool.bind(some_canvas_item, 4092)

# 2) 一条纯提示（教程气泡就是这条路径）
DialogueTool.show_text("点这里继续", target_rect, view_size)

# 3) 一段对话
var session := DialogueTool.play(my_script, {"actor": player})
DialogueTool.advance()      # 玩家点击/按键推进
DialogueTool.is_playing()

# 4) 目标移动：每帧把锚点喂进去
DialogueTool.set_anchor(target_rect, view_size)
```

## 换成项目自己的样子

三种方式，从轻到重：

1. **只改样式**：主题里配 `DialogueBubble/panel`，或设 `BubblePresenter.style / font_size`。
2. **改默认实现的局部**：继承 `BubblePresenter`，覆盖 `_build_view()` / `_apply_style()` / `_layout_slots()`。
3. **完全自己实现**：
   ```gdscript
   class_name MyDialogueView extends DialoguePresenter
   func present(line, text): ...   # 立绘 / 打字机 / 字幕 / 3D 头顶文字都行
   func dismiss(): ...
   func refresh(): ...
   ```
   然后 `DialogueTool.register(MyDialogueView.new())`，或者 `DialogueTool.presenter_scene = preload("...tscn")`。

## 定位能力（基类已提供）

`placement` 枚举：`FOLLOW_BELOW / FOLLOW_ABOVE / SCREEN_BOTTOM / SCREEN_TOP / SCREEN_LEFT_TOP / SCREEN_CENTER`，
跟随类自带"放不下自动翻到另一边"；`gap`、`screen_margin`、`max_width`、`min_width`、`min_height`、`limit_top`
控制留白与避让；`resolve_position(panel_size)` 可直接复用。

## 插槽

`presenter.attach_slot("portrait", node, Vector2(120, 160))`：框架负责腾位置，节点归项目所有
（立绘、3D 模型子视口、按钮都行）。`detach_slot(name)` 移除，节点不释放。

## 与遮罩的关系

`FocusMask` **不认识气泡**：它只提供 `get_hit_rects()`（目标区域）并把锚点喂给 `DialogueTool`。
所以对话系统可以脱离教程单独用（剧情对话、道具说明、字幕），教程也可以只当"一个使用方"。
