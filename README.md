# ACNextGen_Physics_send

## Phase 3-A — Result Transport Repair

作業対象は **ACNextGen_Physics_send / Phase3-A** です。
`ACNextGen_Enhanced_Physics` リポジトリには変更・pushを行っていません。
`Phase2` と `Phase3` は比較用にそのまま保存しています。

**現在の到達点は転送経路のオフライン検証です。3-A全体の実環境PASS、3-Bの適用、3-Cの統合、ACの車両挙動変化を証明したものではありません。Injectionは無効です。**

### 監査結果

監査基準はPhysics_sendの `0f0daca` と添付ZIPです。`Phase3-A` のRuntime、Bridge、WorkerOutputは添付 `ACNextGen_Phase3A_Complete.zip` と一致していました。

| 場所 | 修正前に確認した内容 | 今回の対応 |
|---|---|---|
| Runtime `ACNextGen.lua` | モジュール更新後の状態を共有。失敗時に以前の参照が残る経路がある | 更新時刻、元の車両必須値、更新/getState失敗を検証し、失敗した参照を無効化 |
| `ngp_core.lua` | 共通ヘルパー。モジュール管理そのものはRuntimeが担当 | 変更なし |
| State Bus | `runtime.moduleStates` / `moduleWheelStates` のライブ参照 | 計算式はそのまま、Hubで転送用の必須値と鮮度を確認 |
| Hub `modules/physics.lua` | 実際のタイヤ結果は各輪lateral/longitudinalに存在。一方Body Forceは未生成で `available=false` | 各輪の実結果と入力状態にsequence/timestampを付ける。Body Forceを合成しない |
| Worker `physics_bridge.lua` 内のソース文字列 | XYZだけを往復。入力sequenceを進めた直後に旧出力と比較するため、通常の非同期順でも出力が無効になる | 未完了入力を上書きせず、応答を読み取ってから次を送信。各輪結果も往復 |
| `worker_output.lua` | `values` がWorker応答ではなくHubそのもの。Error Countを毎回クリア | Workerから返ったスナップショットだけを検証。実エラーと最終原因を保持 |
| `observer.lua` | 入力Body Forceを出力欄へ代入。独自PASS判定でApplied非ゼロも許容 | Validatorの判定を表示。未生成Body ForceはN/A、各輪結果を独立表示 |

修正前の順序は模擬実行で `Input 2 / Output 1`、`Input 3 / Output 2` と連続して拒否されることを再現しました。ただし、過去のAC走行時の「Error Count = 1」の実ログがないため、その1件の原因まで同一だと断定はしていません。

添付Enhanced版の静的監査では、多くのモジュールは内部状態の計算・公開を担当し、Hubも集約・公開が中心でした。`steering_mechanism.lua` の `ac.setSteeringFFB` は確認できましたが、FFB出力を車体への力・モーメント適用の証明として扱うことはできません。各系統の計算値がAC物理にすべて適用されているとは確認できていません。

### 変更範囲と非変更範囲

変更した実行コードは次の5ファイルです。

- `Phase3-A/ACNextGen.lua`
- `Phase3-A/modules/physics.lua`
- `Phase3-A/modules/physics_bridge.lua`
- `Phase3-A/modules/worker_output.lua`
- `Phase3-A/modules/observer.lua`

新規ファイルはオフライン検証用の `Phase3-A/test_transport.lua` です。
既存の11個のcore/計算/監査モジュールは基準コミットとバイト一致を確認しています。Tire Force、Suspension、Drivetrain等のFormula変更はありません。

### 現在のデータ経路

```text
AC Runtime → 計算モジュール → State Bus → PhysicsHub.v1
 → Bridgeの未完了入力 → Physics Worker
 → Worker応答スナップショット → WorkerOutput Validator → Observer
```

Workerでは新しい物理式を計算せず、既存モジュールが計算した結果を検証して返します。
この経路の末端に物理適用APIはありません。

転送対象:

- 車両: `speedKmh`, `rpm`, `steer`, `gear`, `brake`, `gas`
- 各輪（0=FL、1=FR、2=RL、3=RR）: `lateralForce`, `longitudinalForce`, `load`, `slipRatio`, `slipAngle`, `omega`
- メタデータ: `sequence`, `timestamp`, Workerの `tick`, `available`, `valid`
- Body XYZは明示的なproducerが `body.available=true` にした場合だけ有効なチャネルとして扱う。**現在のHubでは未生成のまま**
- 垂直力、ホイールトルク、車体モーメントは未統合。フラグのない数値だけで「適用可能」と判断しない

力・荷重・slip等の値は既存producerの意味・単位を保持しています。AC向け座標変換や、タイヤ力からBody XYZへの合算は行っていません。Load Transfer、Suspension、Yaw、Drivetrain等の独立した全出力が転送済みという意味でもありません。

### Sequence、鮮度、PASSの意味

- Hubのsequenceは、そのスナップショットを取得したRuntime frameです。計算モジュールは既存の30/60 Hzスケジュールのままなので、全producerが同時刻に再計算されたという意味ではありません。
- `Input Sequence` と `Output Sequence` は**最後に受信確認した入力と応答のペア**です。次に処理中の入力は `Pending Sequence` に分離しています。
- Worker TickはWorker独自の更新回数です。Runtimeと更新周波数が違うため、入力sequenceと同じ数になることは要求しません。応答sequenceと送った入力sequenceは厳密一致が必要です。
- 送信側・受信側とも、payloadを書き終えてからsequenceを確定します。Workerは完成した応答を次の入力まで変更しません。app/workerの接続layoutは同じ定義から生成します。
- `Transfer Count` は送信試行数ではなく、内容・sequence・鮮度を検証して受信確認した回数です。
- `timestamp` はHub取得時の `runtime.time`（秒）。観測しただけで時刻を更新しません。Worker heartbeatと結果の年齢を別々に確認します。既定の応答/heartbeat上限は0.75秒、Hub側producerの更新時刻上限は0.10秒です。
- `PHASE_3A_TRANSPORT_PASS`: 対応する応答が有効で、その検証周期のTransfer Deltaが正、エラーなし、Injection無効、Appliedゼロ。
- `PHASE_3A_TRANSPORT_FRESH`: 直近スナップショットはまだ有効だが、その周期に新しい転送はない。新たなPASSにはしません。
- `available` は受信済みデータの存在、`valid` は現在の利用可否です。古いデータは診断用に存在してもvalidにはなりません。利用可能な `values` は全体の検証失敗時にnilになります。
- 通常の起動待ちはエラーではありません。初回応答タイムアウト、Worker停止、NaN/Inf、応答改変、sequence不一致、時刻逆行、実行時エラー、Injectionガード違反などは追跡可能にします。実エラー履歴がある実行は再PASSさせず、原因確認後にアプリを再読み込みしてください。

**現在は未完了入力1件の方式です。** Worker待ちの間に生成された未送信Hub frameはキューに蓄積せず、応答後に最新値を送ります。これは「全frameの無損失配送」ではありません。全系統の物理レート統合や帯域設計は、実CSPでこの基礎経路を確認してから別途行う必要があります。

### オフライン検証

リポジトリのルートでLuaJIT 2.1を使って実行します。

```sh
luajit Phase3-A/test_transport.lua
```

LuaJITが直接使えない場合は、PythonのLupaに含まれるLuaJIT 2.1でも実行できます。

```sh
python -m pip install lupa
python -c "from lupa.luajit21 import LuaRuntime; LuaRuntime().execute(\"dofile('Phase3-A/test_transport.lua')\")"
```

検証結果: **49テスト、失敗0件**。リポジトリ内Luaファイル47件のLuaJIT構文検証も通過しています。

テストには非同期順序、各輪識別、payload保存、欠損・NaN/Inf・不正型、遅延/初回タイムアウト、Worker停止、古い/未来sequence、時刻逆行、再読み込み、Applied改変、Observer誤判定防止を含みます。実際のRuntimeスケジューラと既存計算モジュールを動かし、非ゼロの計算結果がWorkerを往復する照合も含みます。

テストのAC/CSPオブジェクトは明示的なmockです。共有メモリの実ABI、CPU間のメモリ順序、CSP権限/API互換性、実車両への効果、実環境の性能を証明しません。

### ACでの次の確認

1. 現在のアプリをバックアップする。Enhanced版を上書きして試す必要はありません。別のACテスト環境で確認してください。
2. `Phase3-A/ACNextGen.lua`、`manifest.ini`、`modules/` をテスト環境の `apps/lua/ACNextGen/` に同じ構造で配置する。過去のPhaseと混ぜない。同じ接続を使う複数インスタンスを同時に動かさない。
3. アプリを再読み込みし、CSPのWorker API/接続が利用できるか確認する。未対応なら代替のFake Outputは出しません。
4. ObserverでWorker Alive、Tick Fresh、入力/出力の有効性、対応sequence、Pending Sequence、Transfer Delta、Error Count/Last Errorを記録する。
5. FL/FR/RL/RRのlateral/longitudinalが入力の変化に応じて更新されることを確認する。Body ForceがN/Aであることは現在の実装では正常です。
6. Injection DISABLED、Applied 0を維持する。停止や再読み込みを試す前後のログも保存する。エラーがあれば原因を追跡する。
7. CSPバージョン、車両、コース、条件、Observer画面、ログ、更新負荷を揃えて3-Aの実環境確認を行う。

**3-B/3-Cは未実装・未有効化です。** ACのネイティブタイヤ力へ既存計算値をそのまま足すと二重計上の恐れがあります。Body Forceの所有者、単位・座標系、作用点、additive/replacementの区別、実際に使えるCSP物理APIを確認し、単一値のApplication経路から段階的に進めます。Observerの数値や転送PASSだけで「車が変わった」と判断しません。
