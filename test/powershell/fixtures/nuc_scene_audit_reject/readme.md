# 現場重放 fixture：稽核模式 Init 被拒但事後診斷可準備（#481）

用途：`test/powershell/unit/init_reject_reason_tests.ps1` 重放乾淨安裝後進入稽核模式，在內建 Administrator 桌面以系統管理員身分執行 `init.cmd`，第一次被判為 `RejectUnknownSetupState` 且只顯示「狀態未知」、不說明原因的問題。

## 欄位來源

- `UnfixedMessage`：未修版（main `bfdccab4`）第一次執行時顯示的錯誤原文。
- `DiagnosticModeFacts`、`DiagnosticContext`、`DiagnosticRoute`：稍後在同一臺、同一工作階段以唯讀方式執行 `Get-SetupInitPreparationFacts` 與 `Get-InitRoute` 讀到的值，照原值保留；`SetupInProgress` 當時未記錄，不列入。
- `ImageState`：兩次相同。
- `Sid`：以合成值 `S-1-5-21-1-2-3-500` 取代實際 SID，只保留內建 Administrator 的 `-500` 結尾。

## 未知

- 第一次被拒時的 ModeFacts 沒有記錄，**實際不符的條件未知**。使用者確認當時同工作階段沒有開著的 Sysprep 對話框，所以不是 Sysprep 對話框。兩次之間可能變動的條件包括同工作階段的 OOBE／setup 程序、讀取例外、OOBE API 結果與桌面擁有者判定。
- 因此測試只重放事後診斷（應為 `PrepareOobe`），並逐項確認每個條件不符時的拒絕訊息與本機紀錄；不重建、不假設第一次被拒時的狀態。

## 限制

- 結果只代表該台電腦在該次系統狀態，不可直接套用至另一台電腦。
