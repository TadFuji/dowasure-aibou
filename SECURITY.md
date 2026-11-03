# セキュリティ

## 問題を見つけたら

鍵（API キー）や個人の情報が見えている、記録が意図せず外に送られている、などの問題を見つけた時は、**公開の Issue には書かず**、GitHub の [非公開の脆弱性報告](https://github.com/TadFuji/dowasure-aibou/security/advisories/new) からお知らせください。

## このアプリが守っていること

- 記録は iPhone の中だけに保存します。開発者のサーバーはありません。
- AI（Anthropic の Claude API）には、処理に必要な分だけを送ります。
- 鍵は iPhone のキーチェーンに「この iPhone だけ」の設定で保存します。
- このリポジトリには鍵・個人の記録を入れません。コミット前の点検（`.githooks/pre-commit`）と、GitHub Actions の点検で二重に防いでいます。

詳しくは [docs/プライバシーと安全.md](docs/プライバシーと安全.md) を見てください。

## 対象

ハッカソン（Built with Claude: Japan 2026）の応募作品です。最新の `main` だけを対象にしています。
