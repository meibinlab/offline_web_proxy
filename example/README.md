# example

offline_web_proxy の WebView delegate 向け推奨アクション API を確認するためのサンプルアプリです。

## できること

- ローカル upstream と proxy をその場で起動し、WebView で proxy URL を表示
- NavigationDelegate で recommendMainFrameNavigation を呼び、内部遷移と外部委譲候補を判定
- 擬似 new window 操作で recommendNewWindowNavigation を呼び、target=_blank 相当の推奨動作を確認
- 同一 origin の絶対 URL を proxy URL へ戻す流れを確認
- 電話リンクや地図リンクを遷移前にキャンセルする例を確認
- requestReceived イベントの data に含まれる resolvedUpstreamUrl などを画面ログで確認

## 起動

```bash
cd example
flutter run
```

起動後は次を確認できます。

- WebView 内の relative same-origin link
- absolute same-origin link
- phone link
- maps link
- target=_blank 判定ボタン

外部リンクは実際の外部アプリ起動までは行わず、サンプルでは遷移をキャンセルして判定結果を表示します。
