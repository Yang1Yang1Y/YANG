# Codex 用量宠物 v3.0.0

这是首个可作为普通 Windows 软件安装和卸载的版本。

## 主要内容

- 安装时可选择目标目录，默认安装到当前用户目录，无需管理员权限。
- 可选择桌面快捷方式和开机启动，并自动创建开始菜单入口。
- 提供完整卸载程序；只删除本软件的设置与派生缓存，不会删除 `%USERPROFILE%\.codex` 中的原始会话日志。
- 安装版无需 Git。发现新的 GitHub Release 后会提示用户，并在确认后下载更新。
- 更新包经过 SHA256 校验，失败时保留原版本并记录更新日志。
- 同时提供标准安装包与便携 ZIP。

> 首个版本尚未使用商业代码签名证书，Windows SmartScreen 可能显示“未知发布者”。请只从本仓库的 Releases 页面下载，并可使用 `SHA256SUMS.txt` 核对文件。

## 下载

- 推荐：`CodexUsagePet-Setup-v3.0.0.exe`
- 便携版：`CodexUsagePet-portable-v3.0.0.zip`
- 校验：`SHA256SUMS.txt`
