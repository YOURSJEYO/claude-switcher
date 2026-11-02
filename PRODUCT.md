# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

需要在一台电脑上隔离多个 Claude 账号的用户。Windows 用户通过原生 WPF 界面完成环境检查、账号切换、快照迁移和代理维护。真实使用场景来自现有产品与本次明确需求；未另行扩展用户角色。

## Product Purpose

在保持账号登录态与本地身份隔离的同时，让用户明确知道当前账号、网络与环境是否适合启动 Claude，并能安全切换和恢复各账号状态。

## Positioning

以环境审计、Fail-Closed 防护、账号快照和独立配置目录形成账号安全切换流程，而不是简单的启动器或登出工具。

## Operating Context

现有 Windows 版本使用 PowerShell 5.1+ 与原生 WPF。主要任务包括查看 14 项检查、选择 A–D 账号、重新检查、一键修复、切换代理客户端以及使用维护和快照工具。macOS 与 Linux 版本保留各自既有界面机制。

## Capabilities and Constraints

必须保留现有账号切换、环境审计、代理检测、快照、诊断、更新和设置行为。真实账号、凭据、Clash 配置和系统服务不属于视觉开发验证范围。界面状态只能来自现有核心输出，不虚构安全通过或真机验收结果。

## Brand Commitments

产品名称为 Claude 切换器。用户已明确批准一版深色、专业、信息层级清晰的 Windows 概念稿，作为本次视觉实现依据。

## Evidence on Hand

- 当前实现：`windows/SwitcherUI.ps1`
- 已确认概念稿：用户回复“可以，做的很棒，开始吧”
- 产品安全边界：`AGENTS.md`、`SECURITY.md`
- Windows 行为说明：`windows/README.md`

## Product Principles

- 当前账号与环境状态首先可读。
- 主要操作明确，次要工具不抢占注意力。
- 状态颜色与文字共同表达，不只依赖颜色。
- 视觉优化不得改变安全语义、核心命令或本机安装态。
