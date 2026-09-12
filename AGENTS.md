# 仓库约定（请遵守）

## 版本号
- **修 bug / 迭代过程中不要改 `version.txt`，也不要打新 tag。**
- 等用户实际看过、确认没有问题了，再统一升版本号并打 `vX.Y.Z` tag。
- 需要给某一版留档时用 `git tag -f` 把 tag 指到最终的修复提交即可。

## 构建与验证
- 构建：`./scripts/build_app.sh release`（写入 `dist/`、归档到 `dist/archive/<version>/`、杀掉旧进程并自动打开 App）。
  仅编译不打开：`NO_OPEN=1 ./scripts/build_app.sh release`。
- 版本号单点来源是 `version.txt`，`BuildInfo.generated.swift` 由脚本生成，不要手改。
- 改动弹幕 / 播放相关逻辑时，至少实测一次「进入全屏 → 退出全屏」的过渡。

## 回退
- 每个版本都有 tag（`git tag`），回退用 `git checkout vX.Y.Z`。
