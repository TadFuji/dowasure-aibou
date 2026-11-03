---
name: pre-publish-check
description: 提出前に、非公開のリポジトリを公開へ戻す前の点検をする。鍵・個人の記録・実名が無いか、文書が最新か、を確かめてから藤川さんに公開の承認をもらう。「公開に戻す」「提出の準備」「公開前の点検」と言われた時に使う。
---

# 公開前の点検

2026-11-03、藤川さんの判断でリポジトリを非公開にした（アイデアの保護と、うっかり載せた時の影響を小さくするため）。大会のルールで、提出時は **公開が必須**。締切は 2026-11-08（日）20:00 JST。

公開は外から見える変更なので、**点検の結果を藤川さんに見せ、承認をもらってから** 切り替える。

## 1. 秘密情報

全履歴を対象に、作った本人とは別の目（サブエージェント）でも点検する。

```bash
git log -p --all | grep -nE 'sk-ant-[A-Za-z0-9_-]{10,}|AIza[0-9A-Za-z_-]{35}'   # 何も出ないこと
git ls-files | grep -E '^(secrets|private-data)/'                              # 何も出ないこと
git log --all --format='%ae' | sort -u                                          # noreply のアドレスだけ
```

- GitHub Actions「点検」が main で成功していること。
- 藤川さんの本物の記録、他人の実名、電話番号、住所が入っていないこと（`Fixtures/`、`SampleData.swift`、`docs/`、画像）。
- スクリーンショットや動画に、本物の記録や鍵が写っていないこと。

## 2. 文書

- `README.md` の「いまできること」「正確さ」「動かし方」が、最新のアプリと合っていること。
- `docs/開発記録.md` の最後の項が、提出直前の状態まで追いついていること。
- `docs/` の数字（テスト数、採点の結果）が最新であること。
- `python3 .github/scripts/check_links.py` でリンク切れが無いこと。
- `handoff.md` など作業用のファイルを残すかを藤川さんに確認する。

## 3. 公開へ戻す（藤川さんの承認の後）

```bash
gh repo edit TadFuji/dowasure-aibou --visibility public --accept-visibility-change-consequences
gh repo view TadFuji/dowasure-aibou --json visibility   # "PUBLIC" を確かめる
```

ログインしていないブラウザ（シークレットウィンドウ）で、README が見えることも確かめる。

公開した後、GitHub の Settings → Security で「Private vulnerability reporting」を有効にする（`SECURITY.md` の報告先がこれを使う。非公開のリポジトリでは使えない）。リポジトリの説明文とトピックも設定する。

## 4. 記録

`docs/開発記録.md` に、点検の結果と公開した時刻を書く（dev-log スキルの形で）。
