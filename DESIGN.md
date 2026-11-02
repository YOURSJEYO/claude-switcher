---
name: "Claude 切换器 · Windows"
description: "以清晰状态层级和克制蓝色强调构成的专业深色账号安全操作台"
colors:
  window-bg: "#0B1120"
  sidebar-bg: "#0F172A"
  dialog-bg: "#12141D"
  card-bg: "#131E31"
  control-bg: "#162238"
  control-hover-bg: "#1D2C46"
  control-pressed-bg: "#101B2D"
  guard-bg: "#122438"
  update-bg: "#172F51"
  accent: "#2563EB"
  accent-border: "#3B82F6"
  accent-hover: "#60A5FA"
  accent-soft-text: "#93C5FD"
  text-primary: "#F4F7FB"
  text-control: "#E6EDF7"
  text-muted: "#9AA9BF"
  text-subtle: "#7F93AD"
  text-faint: "#64748B"
  border: "#2A3952"
  border-sidebar: "#22304A"
  border-row: "#223049"
  border-guard: "#24415E"
  focus: "#FBBE24"
  success: "#22C55E"
  success-soft: "#34D399"
  warning: "#FBBE24"
  warning-row: "#FACC15"
  error: "#F87171"
  waiting: "#6B7280"
  account-icon-bg: "#22324C"
  account-icon-text: "#C8D7EE"
  field-bg: "#FFFFFF14"
  field-border: "#FFFFFF33"
typography:
  display:
    fontFamily: "Segoe UI"
    fontSize: "26px"
    fontWeight: 700
  headline:
    fontFamily: "Segoe UI"
    fontSize: "21px"
    fontWeight: 700
  title:
    fontFamily: "Segoe UI"
    fontSize: "15px"
    fontWeight: 600
  body:
    fontFamily: "Segoe UI"
    fontSize: "12px"
    fontWeight: 400
  label:
    fontFamily: "Segoe UI"
    fontSize: "10px"
    fontWeight: 400
  mono:
    fontFamily: "Consolas"
    fontSize: "12px"
    fontWeight: 400
rounded:
  control: "8px"
  account-icon: "9px"
  panel: "10px"
  badge: "12px"
  card: "14px"
spacing:
  gutter: "16px"
  card-padding: "18px"
  status-padding: "20px"
  content-x: "30px"
  content-top: "28px"
  content-bottom: "24px"
  sidebar-x: "18px"
  dialog: "22px"
components:
  button-secondary:
    backgroundColor: "{colors.control-bg}"
    textColor: "{colors.text-control}"
    rounded: "{rounded.control}"
    padding: "14px 9px"
    height: "38px"
  button-secondary-hover:
    backgroundColor: "{colors.control-hover-bg}"
    textColor: "{colors.text-control}"
    rounded: "{rounded.control}"
    padding: "14px 9px"
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "#FFFFFF"
    rounded: "{rounded.control}"
    padding: "14px 9px"
    height: "38px"
  card:
    backgroundColor: "{colors.card-bg}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.card}"
    padding: "18px"
  account-card:
    backgroundColor: "{colors.card-bg}"
    textColor: "{colors.text-control}"
    rounded: "{rounded.control}"
    padding: "14px"
    height: "126px"
  account-card-current:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.text-control}"
    rounded: "{rounded.control}"
    padding: "14px"
    height: "126px"
  field:
    backgroundColor: "{colors.field-bg}"
    textColor: "#FFFFFF"
    padding: "10px 8px"
---

# Design System: Claude 切换器 · Windows

## Overview

**Creative North Star: "安全操作台"**

Windows 界面是一座以判断与操作为中心的安全操作台：当前账号、环境结论和主要动作首先可读，账号快照、14 项检查与维护工具按任务层级展开。整体采用专业深色、卡片式总览和紧凑但可扫描的信息密度。

蓝色只承担主要操作、当前账号和导航定位；成功、警告、失败与等待状态同时使用文字、符号和颜色。界面不以装饰制造安全感，状态始终来自现有核心输出。

**验证边界：** 本文件记录 `windows/SwitcherUI.ps1` 的已实现设计，不代表 Windows/WPF 真机渲染、窗口缩放、键盘操作或完整交互流程已经验收。

**Key Characteristics:**
- 专业深色与清晰状态层级
- 克制蓝色强调与卡片式账号、环境总览
- 边框和 tonal layering 建立深度，不使用阴影
- 颜色与文字共同表达安全状态

## Colors

主窗口以深海军蓝为底，蓝色集中标记主要动作和当前位置；语义色仅用于真实状态反馈。

### Primary
- **操作蓝**：用于“一键修复”等主要按钮及当前账号卡，建立明确的操作优先级。
- **导航亮蓝**：用于按钮悬停描边、当前导航左边线和英文眉题。
- **状态浅蓝**：用于当前账号值、信息横幅等需要被注意但非警告的内容。

### Neutral
- **窗口深海蓝**：主窗口底色。
- **侧栏深蓝**：固定导航区域，与主内容形成第一层 tonal 分区。
- **卡片蓝灰**：账号、环境、工具和状态卡的共同表面。
- **控件蓝灰**：按钮、下拉框等可操作表面的默认底色。
- **主文字冷白**与**控件文字浅灰**：分别承担窗口正文和控件内容。
- **三级灰蓝文字**：辅助说明、次级说明和低优先信息依次使用 muted、subtle、faint。
- **结构描边**：卡片、侧栏、检查行和防护卡使用各自的低对比蓝灰边线，不依赖阴影分区。

### State
- **通过绿**：检查行“通过”和成功状态；不得把灰色跳过显示为通过。
- **注意黄**：等待、警告、检查中及键盘焦点；检查行警告使用独立的亮黄。
- **失败红**：失败状态与表单错误。
- **等待灰**：尚未返回结果的检查行和“跳过”。

**The Status Has Words Rule.** 状态必须保留“通过 / 警告 / 跳过 / 失败”等文字或状态符号，颜色不能成为唯一信息载体。

## Typography

**Display Font:** Segoe UI
**Body Font:** Segoe UI
**Label/Mono Font:** 常规标签使用 Segoe UI；维护工具输出使用 Consolas。

**Character:** 单一系统无衬线字体维持 Windows 工具的熟悉感；字号、字重和灰度共同建立层级，英文眉题只作辅助定位。

### Hierarchy
- **Display**（Bold，26px）：主窗口“账号与环境”标题。
- **Headline**（Bold，21px）：维护工具弹窗标题；其他弹窗使用已实现的 18–20px 粗体标题。
- **Title**（SemiBold，15–16px）：卡片标题、环境结论与账号分区标题。
- **Body**（Regular，11–12px）：正文、检查项与操作说明。
- **Label**（Regular / Bold，10–11px）：眉题、辅助元信息、状态标签与底部操作。
- **Mono**（Regular，12px）：只读体检和工具输出。

## Layout

主窗口初始为 1100×900，最小为 680×700；完整布局由 224px 侧栏和可纵向滚动的主内容组成。主内容水平留白 30px，顶部 28px、底部 24px；主要双栏按 3:2 分配，栏间为 16px。

宽度小于 960px 时，侧栏收窄为 78px，品牌说明和防护卡隐藏，导航切换为单字标签；环境与代理、检查与工具改为单列，账号卡由四列改为两列。宽度小于 720px 时隐藏侧栏，页头操作移至标题下方。弹窗使用 22px 外边距，维护工具以两列按钮网格组织。

## Elevation & Depth

系统不新增阴影。深度由窗口、侧栏、卡片、控件之间的 tonal layering 与 1px 结构边框建立；当前导航额外使用 3px 左侧蓝色边线，键盘聚焦按钮使用 3px 黄色边框。弹窗内输出和设置分组使用低透明度白色表面。

**The Border Before Shadow Rule.** 需要区分层级时，先使用既有表面色与描边，不以投影制造浮起效果。

## Shapes

主卡片使用柔和的大圆角（14px）；防护卡、品牌标记、状态图标和状态胶囊使用 12px；按钮、导航和更新条使用 8px；账号字母标记为 9px，弹窗分组为 10px。细边框勾勒可操作区域与容器，检查行只保留底部分隔线。

## Components

### Buttons
- **Shape:** 紧凑圆角（8px），默认最小高度 38px，半粗体。
- **Primary:** 操作蓝底、白字和亮蓝描边，只用于当前主要动作。
- **Secondary:** 控件蓝灰底、浅灰字和结构描边。
- **Hover / Pressed:** 悬停切换为较亮表面与导航亮蓝描边；按下回到更深的 pressed 表面。
- **Keyboard Focus:** 黄色 3px 边框；禁用通过 0.55 不透明度表达。
- **Navigation:** 默认透明、左对齐；当前项为浅层蓝底与 3px 左侧亮蓝边线。

### Cards / Containers
- **Corner Style:** 主卡片 14px。
- **Background:** 统一卡片蓝灰；当前账号卡切换为操作蓝。
- **Shadow Strategy:** 无阴影，遵循边框和 tonal layering。
- **Border:** 1px 结构描边。
- **Internal Padding:** 常规卡片 18px，环境状态卡 20px。

### Account Cards
- **Structure:** A–D 四张可点击卡，每卡最小高度 126px、内边距 14px；字母标记为 32×32、圆角 9px。
- **State:** 副标题显示“当前 / 未初始化 / 已建档”等真实核心状态；当前卡使用操作蓝底，其余保持卡片蓝灰。
- **Availability:** 忙碌或环境未就绪时禁用，不以视觉样式暗示可绕过检查。

### Status
- **Hero Status:** 46×46 状态符号区、环境结论和胶囊标签共同组成总览。
- **State Mapping:** 成功使用 ✓，失败使用 !，等待与进行态使用 …；图标、胶囊和侧栏状态点同步更新。
- **Check Rows:** 检查名、详情和状态文字组成三列；详情省略时保留 ToolTip，行底使用细分隔线。

### Inputs / Fields
- **Style:** 文本框与密码框使用 8% 白色底、20% 白色描边和白色文字；文本框内边距 10px 8px。
- **Selection:** 文本选择使用操作蓝，光标为白色。
- **Error:** 弹窗错误使用失败红文字；未实现独立焦点样式，不补写视觉验收结论。
- **Read-only Output:** 维护工具输出使用 Consolas 12px、透明底和自动纵向滚动。

### Navigation
- **Style:** 224px 深色侧栏；当前项有蓝底和左侧亮线，其他项透明。
- **Compact:** 960px 以下变为 78px 并显示单字标签，720px 以下隐藏。

## Do's and Don'ts

### Do:
- **Do** 让当前账号、环境状态和主要操作先于维护工具被读到。
- **Do** 使用文字或符号与颜色共同表达检查状态。
- **Do** 用既有表面色和 1px 边框建立卡片与区域层级。
- **Do** 在窄窗口使用已实现的 960px 与 720px 布局变化。

### Don't:
- **Don't** 新增阴影或把装饰性蓝光当作状态反馈。
- **Don't** 将灰色“跳过”呈现为绿色“通过”，或虚构环境安全结论。
- **Don't** 让次要维护工具使用比主要修复动作更强的视觉权重。
- **Don't** 将本文的静态实现记录当作 Windows/WPF 真机渲染与交互验收。
