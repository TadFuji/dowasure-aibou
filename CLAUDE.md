# CLAUDE.md（ど忘れ相棒）

藤川さん（非プログラマー）の iPhone アプリ。目的（藤川さんの言葉、2026-11-03）：「忘れてしまうだろうなと思ったことをパッと話して記憶してくれる。そして『何だっけな』と思い出すときに、答えを言うのではなくてヒントを言う。」コードの確認・修正・テストはすべて Claude が行う。仕様の原本はプロジェクトファイル「ど忘れ相棒_仕様書_2026-10-14.md」。ハッカソン提出締切 2026-11-08 20:00 JST。

## 守ること

- 変更・問題・原因・対応・結果は `docs/開発記録.md` に時系列で必ず追記する（藤川さんの常設依頼。最終レポートの材料）。書き方は `.claude/skills/dev-log/` に従う。リポジトリを公開へ戻す前は `.claude/skills/pre-publish-check/` の点検をする。

- このリポジトリは公開する。API キー・藤川さんの本物の記録・他人の実名を入れない。デモ用データは `SampleData.swift` の架空データだけ。`.githooks/pre-commit` が `sk-ant-` と `private-data/` をはじく（`git config core.hooksPath .githooks` が前提）。
- 医療・診断めいた機能や文言を入れない。
- 利用者は高齢者：高い音が聞こえにくい前提で、音は低め（通信音は1kHz未満）、声は低め・ゆっくり・はっきり。文字とボタンは大きく、音だけに頼らず必ず文字でも示す（2026-11-03 藤川さんの指示「全体的に」）。シニアフリー・ユニバーサルデザイン：白文字の背景色はコントラスト比4.5以上（`Palette` を使う。システムのオレンジ・緑は約2.2で不可）、警告は `WarningText`（印＋言葉）、ボタンの文字は `wrapsForLargeText()` で最大の文字サイズでも途切れさせない、操作の開始・終了は振動でも知らせる、間違いは取り消せるようにする。
- Managed Agents は使わない（記録を端末外に保存しないため）。
- 期間中に新規作成したコードだけを使う。

## 構成

- `DowasureCore/`（Swift Package、Mac でもテストできる中核）
  - `ClaudeClient.swift`: Messages API を URLSession で直接呼ぶ。`output_config.format`（json_schema）で構造化出力。Haiku 5.5 は thinking が既定でオンなので、最初の `text` ブロックを読む。`temperature` などは送らない（400 になる）。
  - `Prompts.swift`: 要約役・相談役のシステムプロンプトとスキーマ。固定文にしてキャッシュが効くようにする。
  - `Retriever.swift`: 端末内で候補日を絞る（時期の言葉→日付範囲、名前一致＋文字2つ組の重なりで順位付け、最大7日）。
  - `Services.swift`: `Recorder`（抜き出し）と `Answerer`（相談）。`Answerer.verify` が根拠日付を「AI に渡した日」だけに絞り、日付の文言をコードで組み立てる。根拠が残らなければ「見当たりません」に倒す。
- `App/`（SwiftUI。SwiftData の `StoredDay` に DayRecord を JSON で保存。API キーはキーチェーン）
- `App/Voice.swift`: 音声認識（Speech、ja-JP、端末内が使えれば端末内）と読み上げ（AVSpeechSynthesizer）。Speech/TCC/音声タップのコールバックは別スレッドで来るので、必ず `nonisolated` の関数の中で登録する（MainActor 扱いになると `dispatch_assert_queue` で落ちる。2026-11-02 に実際に落ちた）。
- `DowasureCore/Sources/DowasureEval` と `Fixtures/`: 採点テスト。`swift run DowasureEval`（検索だけ、通信なし）、`swift run DowasureEval --live`（実 API。キーは `secrets/anthropic_api_key`）。結果は `eval-results/latest.json`（コミットしない）。
- `App/EveningReminder.swift`: 毎晩の通知（UNCalendarNotificationTrigger、既定20:00）。通知をタップすると AppRouter 経由で聞き取り画面を開く。
- `UITests/`: 画面の通しテスト。起動引数 `-uitest-no-voice` で読み上げとマイクを止める。起動引数 `-uitest-reset`（記録とキーを消す）、`-uitest-reset-records`（記録だけ消す）。
- `project.yml` から xcodegen で `.xcodeproj` を生成する（`.xcodeproj` はコミットしない）。

## 起動とテスト

```bash
cd "/Volumes/ROCKET_XTRM/coding/Built with Claude/DowasureCore" && swift test
cd "/Volumes/ROCKET_XTRM/coding/Built with Claude" && xcodegen generate && xcodebuild test -project DowasureAibou.xcodeproj -scheme DowasureAibou -destination 'platform=iOS Simulator,name=Dowasure-iPhone' -derivedDataPath build/dd
```

- 実 API を使う画面テスト（testAskWithKeyAnswersWithDate）は `secrets/anthropic_api_key` があるときだけ動く。キーは起動時の環境変数でアプリ（DEBUG ビルドのみ）に渡り、キーチェーンに保存される。
- シミュレーターは専用の `Dowasure-iPhone`（iOS 26.5）を使う。

## 既知の問題

- 画面テストの最中に `simctl ui content_size` などで表示設定を変えると、シミュレーターの SpringBoard が XCTAutomationSupport 内で落ちた（2026-11-03）。テスト中は設定を変えない。

- Gemini TTS は Tier 1 で1モデルあたり1日100回まで（2026-11-03 確認）。上限時は gemini-3.8-flash-tts に切り替える。試験で藤川さんの枠を使わない（`--voice-demo` や自己点検 `-voice-selftest` は必要な時だけ）。

- iOS 26.5 シミュレーターでは通知の許可要求が usernotificationsd に拒否される（UNErrorDomain 1、requestAuthorization not allowed）。お知らせの実際の動作は実機で確認する。

- シミュレーターでは端末内音声認識の初期化に失敗する（kLSRErrorDomain Code=300）。声の確認は実機で行う。失敗時は画面に「うまく聞き取れませんでした」と出る。
- 採点テストの架空データは Claude が作ったもので30問と小さい。検索の改善（漢字1文字の一致、2026-11-03）はこのデータで効果を確かめたため、過剰に合わせ込んでいる可能性がある。藤川さんの実データで確かめ直す。

- 2026-11-02、iOS 27.0 のシミュレーター機が途中で unavailable（runtime profile not found）になった。iOS 26.5 の専用機で回避中。
- シミュレーター操作ツールの文字入力（貼り付け方式）では日本語が入らなかった。日本語入力の確認は XCUITest の `typeText` で行う。
- シミュレーター操作ツールの screenshot が古い画面を返すことがあった。`xcrun simctl io <機種> screenshot` で撮ると確実。
