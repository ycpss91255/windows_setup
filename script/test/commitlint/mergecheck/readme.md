# 同次新增合併提交檢查

此維護工具使用 `grandfather.json` 的固定主線 anchor 與採用時已公開 PR 的精確 head，可達的既有提交集合對所有事件共用；不根據提交日期、目前 PR head 或執行者輸入擴大豁免。鎖定清單來自兩輪 GitHub API 取樣與人工審核，非原子快照；任何更動需重新審核並更新固定摘要。這是經程式碼審查的防錯措施，不是防止能修改工作流程或來源者的安全邊界。

PR 檢查事件的 base、head、實際 merge checkout 與 tree，僅檢查 PR head 的新可達提交，不把 GitHub 合成 checkout 當作使用者提交。main push 必須有可信 before／after 祖先關係。tag 須解析至實際 checkout、位於固定 anchor 之後且為已核對 main 的祖先；anchor 之前的歷史 tag 不由此新檢查回填，直接拒絕。只支援 main 的 workflow_dispatch；目前 `merge_group` 與其他未知事件明確拒絕，不宣稱已驗證實際 merge queue。來源缺失、淺歷史、baseline 物件無法取得、事件身分矛盾均失敗，不縮小驗證集合。

CI 使用完整 checkout，從固定 GitHub HTTPS 來源取得 manifest 每個精確 SHA 所需物件，不跟隨目前 PR 分支；若上游不再提供某物件會停止並需維護者審查。此工具不修改 branch protection、標籤或既有歷史。原有可選 `commit-msg` hook 的單筆訊息檢查保持獨立。
採用此檢查前已合併至 main 的 `fb7a85067449f316055fe4867318d2037e560455` 標題不符新規則；僅 tag 與 main 手動執行的歷史掃描對該單一提交免除標題檢查。它不是豁免根，祖先與後續提交仍按既定範圍檢查；PR 與 main push 不套用此例外。
