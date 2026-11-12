# Codex入力最適化の記録（2026-11-12）

## 調査範囲と問題
- グローバル `~/.codex/AGENTS.md` は0 bytes。同ディレクトリの override はなし。プロジェクトと親ディレクトリで指示ファイルを確認し、ルートAGENTSを検出。プロジェクト内の指示名検索は生成物・Git・venv・third_partyを除外。追跡対象の指示ファイルはルートのみ。
- ルートAGENTSは7,935 bytes。探索、UTF-8、最小差分、簡潔な返答が複数節で重複。機能別入口3件のパスを訂正した。
- `docs/architecture/`、機能資料、性能実測、READMEが既存Knowledgeに相当する。Phase 0時点の版番号や承認前の計画が混在するため、索引に状態と限界を付けた。本文の一括移動・再確定はしない。
- 過去のauditログや監査文書は残すが通常の読込対象にしない。元の指示に資料全件の必須読込はなかった。現在も索引・本文は必要時のみ参照する。
- 機能・DB・APIは変更せず、元の必須ルールに従ってアプリ/Webの版番号だけを更新する。

## 分類と移行先
| 旧ルール群 | 分類 | 移行先・検証 |
|---|---|---|
| Purpose / Token saving / Output / Expected style | A | AGENTSの目的・探索・完了へ重複統合 |
| Editing / Prohibited behavior | A | 最小差分、既存仕様・コメント・日本語保護を維持 |
| Encoding / Script encoding | A・D | UTF-8明示、文字化け報告、一括変換禁止を統合。今回の変更文書はUTF-8読込で検証 |
| Workspace / Before commands | A・D | ルート確認・SDK直接実行禁止は常設。実行前ガードをworkflowに記載 |
| Flutter project entry points | B | entry-points.mdへ移動・パス訂正 |
| Reading / Investigation / Command execution | A・C | 探索の順序・失敗調査は常設、手順例はworkflowへ |
| Standard commands / 版更新・Release | A・C・D | 実行義務は常設、詳細手順はworkflow。既存テスト・終了コード・成果物版番号で検証 |

自動検証できる部分は実際のコマンドで確認し、目的・影響範囲・日本語の意味・安全性の判断を機械的チェックで代用しない。設定変更を強制する新SkillやCIは追加していない。

## 利用可能なツール・Skill
このセッションで公開されたカタログを基準に確認した。利用可否は次回再確認する。
- MCP: Codexアプリ管理、Document Control、artifact session、node_repl、検索、Sites、プラグイン管理、Pets、安全設定・相談窓口。CUAとシェルも利用可能。
- Skill: OpenAI Docs、imagegen、skill creator/installer、computer-use、documents、PDF、presentations、spreadsheets/Excel、Remotion、Sites、visualize、template creator、work-pets、plugin management。
- ローカル設定には `sts2-ai-agent`、`node_repl` のMCP定義がある。定義の存在はこの作業での接続成功を意味しない。資格情報や接続設定値は転記しない。
- 今回はOpenAI Docsとシェル中心で対応。MCP・Skillの削除、モデル・推論・速度設定の変更はしていない。

AGENTSがコンテキストへ読み込まれる仕様は [公式Codexガイド](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide) を確認。別文書へ移した内容を毎回全件読むと削減効果が失われる。すでに投入された旧指示や会話履歴が、この編集で消えるわけではない。

## 計測方法と限界
同じ依頼・基準コミット・モデル・推論・速度・ツール条件・キャッシュ条件で、別の隔離された作業環境を使い前後を比較する。本番データ・配布を伴う作業を計測のために繰り返さない。課題は関連する既存テストを含む同一内容とし、品質・やり直し回数も比較する。

| 項目 | 最適化前 | 最適化後 |
|---|---|---|
| モデル | 同条件の実行記録なし | 同条件の実行記録なし |
| 推論レベル | 未測定 | 未測定 |
| 速度設定 | 未測定 | 未測定 |
| 入力トークン | 未取得 | 未取得 |
| キャッシュ入力トークン | 未取得 | 未取得 |
| 出力トークン | 未取得 | 未取得 |
| 消費クレジット | 未取得 | 未取得 |
| テスト結果 | 比較用実行なし | 今回の検証結果は下記 |
| 修正やり直し回数 | 比較用実行なし | 同一課題の比較なし |

ローカル設定値は `gpt-6-astra` / `medium` / `service_tier=default` だが、各実行で実際に使われた設定の証明にはならない。API課金やクレジット、トークン数を文字数から推定しない。今回の編集ではパッチ適用形式の修正が1回あり、機能修正の手戻りとは区別する。

## 今回の検証結果
- AGENTS: 7,935 → 3,238 bytes、162 → 25行（実ファイル測定）。トークン消費量とは別の指標であり、消費削減率は未測定。
- 旧AGENTSのバックアップは元の作業ファイルをコピーし7,935 bytesを維持。Git上の内容との比較はCRLF/LF正規化後に一致（最初のバイト比較はGitの改行差で失敗し、内容比較へ修正）。
- UTF-8読込、置換文字の不在、文書リンク、入口パス、3箇所の版番号整合、git diff --check: 成功。
- `flutter test test/services/app_version_service_test.dart --reporter expanded`: 1件成功。版番号比較のテストであり、UI全体の動作保証ではない。
- サンドボックス内のFlutter実行は出力なしで停滞したため中断。通常権限で再実行してテスト成功。比較実験の条件には用いない。
- `flutter build windows --release`: 成功。`build/windows/x64/runner/Release/pdf_viewer.exe` の更新時刻がビルド開始後であること、ProductVersion/FileVersionが `1.0.241+251` であることを確認。webview_windowsのCMake開発者向け警告あり。Web成果物の再生成・配布、全機能テストは今回の対象外。
