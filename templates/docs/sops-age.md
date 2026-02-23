# SOPS + AGE 秘密管理

此 repo 使用 [SOPS](https://github.com/getsops/sops) 搭配 [AGE](https://github.com/FiloSottile/age) 加密每個環境的 secrets，加密後的 `secrets.json` 直接 commit 到 git。

## 概念

每個環境有一份 `overlays/<env>/secrets.json`，內含 Cloudflare Worker 需要的秘密（API key、R2 存取金鑰等）。檔案以 AGE 公鑰加密，只有持有對應私鑰的人或系統能解密。

### 多重收件人

`.sops.yaml` 中每條規則可以列出多個 AGE 公鑰（逗號分隔）：

- **Manager key** — 管理者的個人金鑰，一把 private key 就能解密所有環境
- **Env key** — 環境專屬金鑰，供 CI/CD 使用，只能解密該環境

```yaml
# .sops.yaml 範例
- path_regex: overlays/merlin/secrets\.json$
  age: >-
    age1abc...env_key,
    age1xyz...manager_key
```

## 安裝相依工具

```bash
brew install sops age
```

## 初始設定（Manager，一次性）

### 1. 產生 AGE 金鑰對

```bash
age-keygen
```

輸出範例：
```
# created: 2026-01-01T00:00:00+08:00
# public key: age1ya7gpq...
AGE-SECRET-KEY-1XXXXXX...
```

記下 public key（`age1...`）和 private key（`AGE-SECRET-KEY-1...`）。

### 2. 存入 macOS Keychain

```bash
security add-generic-password -a "sops-age" -s "sops-age-key" -w "AGE-SECRET-KEY-1XXXXXX..."
```

### 3. 加入 `~/.zshrc`

```bash
export SOPS_AGE_KEY=$(security find-generic-password -a "sops-age" -s "sops-age-key" -w 2>/dev/null)
```

重新載入 shell 或執行 `source ~/.zshrc`。

### 4. 驗證

```bash
echo $SOPS_AGE_KEY  # 應該印出 AGE-SECRET-KEY-1...
```

## 日常操作

所有指令都從 overlay 目錄執行：

```bash
cd overlays/<env>
```

### 編輯 secrets

```bash
make edit-secrets
```

會用 `$EDITOR`（預設 `vim`）開啟解密後的 JSON，儲存關閉後自動重新加密。編輯完 commit 即可。

### 查看 secrets（唯讀）

```bash
sops decrypt secrets.json | jq .
```

### 只推送 secrets 到 Cloudflare

```bash
make push-secrets
```

解密 `secrets.json` 並透過 `wrangler secret bulk` 批次上傳。

### 完整部署（程式碼 + secrets）

```bash
make deploy
```

如果 `secrets.json` 存在，部署完成後會自動推送 secrets。

## 新增 Manager

當有新的管理者加入：

1. 新管理者執行上面的「初始設定」步驟，取得自己的 public key
2. 將新 public key 加到 `.sops.yaml` 中每條規則的 `age` 欄位（逗號分隔）
3. 對每個環境重新加密，讓新管理者也能解密：

```bash
sops updatekeys overlays/<env>/secrets.json
```

4. Commit `.sops.yaml` 和所有更新過的 `secrets.json`

## 新增環境的 CI/CD 金鑰

每個環境可以有獨立的 AGE 金鑰給 CI/CD 使用：

1. 產生環境專屬金鑰：
   ```bash
   age-keygen
   ```
2. Private key 存為 CI/CD 的 secret 環境變數（`SOPS_AGE_KEY`）
3. Public key 加到 `.sops.yaml` 對應規則的 `age` 欄位
4. 重新加密：
   ```bash
   sops updatekeys overlays/<env>/secrets.json
   ```

## 疑難排解

### `error loading config: no matching creation rules found`

SOPS 找不到 `.sops.yaml` 中符合的規則。確認：
- 你在 repo 根目錄執行，或使用 `--filename-override` 指定路徑
- `.sops.yaml` 中有對應環境的 `path_regex`

### `could not decrypt data key`

你的 AGE private key 無法解密這份檔案。確認：
- `SOPS_AGE_KEY` 環境變數有設定且正確
- 你的 public key 有列在 `.sops.yaml` 對應規則中
- 如果 public key 是新加的，需要先執行 `sops updatekeys`
