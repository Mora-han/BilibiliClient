# 仓库约定（请遵守）

## 版本号
- **修 bug / 迭代过程中不要改 `version.txt`，也不要打新 tag。**
- 等用户实际看过、确认没有问题了，再统一升版本号并打 `vX.Y.Z` tag。
- 需要给某一版留档时用 `git tag -f` 把 tag 指到最终的修复提交即可。

## 构建与验证
- 构建：`./scripts/build_app.sh release`（写入 `dist/`、杀掉旧进程并自动打开 App）。
  仅编译不打开：`NO_OPEN=1 ./scripts/build_app.sh release`。
- 默认**不再**往 `dist/archive/` 堆历史 `.app`：每个版本都能从 tag 重建（见「回退」），
  正式发布由 GitHub Releases 留存，本地只保留 `dist/BilibiliClient.app` 这一份最新构建。
  确实需要本地留档时用 `KEEP_ARCHIVE=1 ./scripts/build_app.sh release`。
- 版本号单点来源是 `version.txt`，`BuildInfo.generated.swift` 由脚本生成，不要手改。
- 改动弹幕 / 播放相关逻辑时，至少实测一次「进入全屏 → 退出全屏」的过渡。

## 回退
- 每个版本都有 tag（`git tag`），回退 = 检出 tag 再重建：
  `git checkout vX.Y.Z && NO_OPEN=1 ./scripts/build_app.sh release`。
- 从 tag 重建会覆写受版本控制的 `BuildInfo.generated.swift`，切回主线时用 `git checkout -f main`。
