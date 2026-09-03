# 最小対応 —「`rm -rf standalone_xml_history` の 1 行だけ」で効果はあるか

対象の問い:

> 対処法として、本当に最小対応として
>
> ```dockerfile
> # 2) ★ イメージに履歴を残さない (overlayfs の EXDEV を原理的に消す)
> RUN rm -rf "${JBOSS_HOME}/standalone/configuration/standalone_xml_history"
> ```
>
> **だけ**の対応でも効果はあるのか。

関連文書:

* 全体像と原因分析 … [standalone-xml-history-ecs-vs-compose.md](./standalone-xml-history-ecs-vs-compose.md)
* この 1 行の安全性・十分性の詳細検証 … [shortest-fix-safety-analysis.md](./shortest-fix-safety-analysis.md)

本書はその 2 つの結論を「最小対応でどこまで戻せるか」という観点で要約したものである。

---

## 0. 結論

| 問い | 答え |
|---|---|
| **WFLYCTL0056 / 0414 (EXDEV 由来) は消えるか** | **はい。この 1 行だけで原理的に消える** |
| **ECS だけ異常終了する事象は直るか** | **保証できない。別途切り分けが必要** |
| **入れて壊れないか** | **壊れない。ただし 3 章の 2 点を事前確認すること** |

**位置づけ**: 「切り分けの邪魔になる既知のノイズを、副作用ほぼゼロで確実に消す一手」。
異常終了の原因特定と**並行して**入れるべきものであり、これ単独を修正の完了とみなしてはいけない。

---

## 1. なぜ 1 行で足りるのか

実行時に `standalone_xml_history` 配下が **upper 専用 (pure upper) ディレクトリ**として
新規に作られるため、二重に安全になる
(詳細: [shortest-fix-safety-analysis.md 3-2](./shortest-fix-safety-analysis.md))。

1. 初回ブート時点で `current` が**空**なので、`ConfigurationFile#createHistoryDirectory()` の
   早期リターン (★A) により **rename 自体が呼ばれない**
2. 仮に `current` が非空でも (= 起動時 `embed-server` を残した場合)、
   lower レイヤを持たないので **ディレクトリ rename が成功する**

```
【変更前】
  イメージ layer : configuration/standalone_xml_history/current/...
  → current は lower を持つ merged ディレクトリ
  → ovl_rename() が EXDEV → JDK が mkdir+rmdir にフォールバック
  → rmdir が ENOTEMPTY → DirectoryNotEmptyException → WFLYCTL0056 + 0414 (毎起動・毎 :reload)

【変更後】
  イメージ layer : standalone_xml_history に対する whiteout
  → 起動時 lookup が whiteout で停止 → 「存在しない」
  → mkdir で upper 専用として作成 (lower 対応物なし)
  → rename(2) が成立。かつ current は空なので rename 自体が発生しない
```

> **重要**: したがって **起動時の CLI 適用 (`entrypoint.sh` の `embed-server`) を残したままでも
> EXDEV は消える。**
> ビルド時適用 (`APPLY_TLS_CONFIG_AT_BUILD`) は EXDEV のための打ち手ではなく、
> **二重ブートストラップを潰す**という別目的の打ち手である。
> この 2 つを混同しないこと。

この帰結は overlayfs の仕様と WildFly のコードだけから導かれるため、
**環境に依存しない** (ECS / Compose / EC2 / ローカルすべて同じ)。

---

## 2. 1 行だけにすると「残るもの」

| 残る問題 | 影響 |
|---|---|
| 起動あたりの設定ブートストラップが **2 回のまま** | 起動時間・メモリピーク・書き込み量が増えたまま → ECS 側の候補 **(b) ヘルスチェック超過 (exitCode 143)** / **(c) OOM (137)** は潰せない |
| 原因 errno が **EACCES / EPERM** (所有者・権限不一致) の場合 | **効かない**。[15-(a)](./standalone-xml-history-ecs-vs-compose.md#15-この構成でecs-だけ異常終了するときの切り分け) の uid 不一致対処が必要 |
| 原因 errno が **EROFS** (read-only) の場合 | **効かない** (現行構成では発生しないはず) |

### 2-1. どの errno かの判別法

ログの **WFLYCTL0414 の直前**にある **WFLYCTL0056** の原因例外を見る。

| 原因例外 | 意味 | この 1 行の効果 |
|---|---|---|
| `DirectoryNotEmptyException` | EXDEV (overlayfs) | ✅ 消える |
| `AccessDeniedException` | EACCES / EPERM | ❌ 効かない |
| `FileSystemException: Read-only file system` | EROFS | ❌ 効かない |

---

## 3. 入れる前に確認すること (2 点)

```bash
# ① そもそもイメージに履歴が焼かれているか (無ければこの 1 行は no-op)
docker run --rm --entrypoint sh <image> -c \
  'ls -la "$JBOSS_HOME/standalone/configuration"' | grep standalone_xml_history

# ② -c (SERVER_CONFIG) に last / initial / boot / vN を渡していないこと ★唯一の破壊ケース
grep -rn 'SERVER_CONFIG' docker-compose*.yml */Dockerfile 2>/dev/null
aws ecs describe-task-definition --task-definition <td> \
  --query "taskDefinition.containerDefinitions[].environment[?name=='SERVER_CONFIG']"
```

* **①がヒットしない場合** … この 1 行は no-op。かつ履歴が実行時生成なら EXDEV は起き得ないため、
  出ている WFLYCTL0414 の原因は **EACCES / EPERM に絞られる** (= 15-(a) が本命)。
  この結果自体が強い診断情報になる。
* **②が未設定または `standalone.xml`** なら安全。
  `last` / `initial` / `boot` / `vN` を渡していると `findMainFileFromBackupSuffix()` が
  履歴を必須とし、無いと `configurationFileNotFound` で**起動できなくなる**。

### 3-1. 安全性のまとめ

* `rm -rf` は対象が無くても成功する → **ビルドは常に成功する** (冪等)
* **イメージサイズは変わらない** (whiteout が増えるだけ)
* `standalone.xml` などの設定ファイル本体には**一切触らない**
* ロールバックは **1 行消して再ビルドするだけ**
* 運用上の履歴 (実際に稼働したサーバの設定変更履歴) は **1 件も失われない**。
  消えるのは「ビルドマシン上の一度きりのブート」の記録だけ

---

## 4. 実装上の注意 2 点

### 4-1. 配置順

履歴を生成し得る RUN (`embed-server` / サーバ起動を伴う処理) より **後**に置くこと。
現行の `base/Dockerfile` は Elytron 設定適用と同一 RUN の末尾に置いてあり、条件を満たしている。

```
JBoss EAP 導入
  └→ (本リポジトリ) Elytron 設定のビルド時適用 + standalone_xml_history 削除
       └→ (seed 方式) configuration → configuration-seed の退避
```

ビルド時適用を外して「1 行だけ」にする場合も、
**ベースイメージ側が履歴を含む可能性がある**ため削除自体は残す価値がある
(=「イメージに履歴を残さない」という不変条件の担保)。

### 4-2. 下流イメージで不変条件を壊さない

* `back/Dockerfile` / `front/Dockerfile` は WAR を COPY するだけ → **問題なし**
* seed 方式側も `rm -rf "${JBOSS_CONF_SEED_DIR}/standalone_xml_history"` で seed から除外済み
* 新たに「ビルド中にサーバを起動する RUN」を追加する場合は、その後ろで再度削除すること

### 4-3. `configuration` にボリューム / tmpfs を当てている構成では無関係

イメージの中身がマスクされるため、この 1 行は効果を持たない。
その場合はボリューム側の内容と所有者が問題になる
([standalone-xml-history-ecs-vs-compose.md](./standalone-xml-history-ecs-vs-compose.md) 5-3 章)。

---

## 5. 進め方の推奨

1. **この 1 行を入れる** — ノイズ (WFLYCTL0056/0414) が消え、真の原因がログから読めるようになる。
   `:reload` 時のローテーションも通るようになる (upper 専用になるため)。
2. **並行して異常終了の原因を切り分ける** — まず `exitCode` / `stoppedReason` を見る。

   ```bash
   aws ecs describe-tasks --cluster <cluster> --tasks <task-arn> \
     --query 'tasks[0].{stopped:stoppedReason,containers:containers[].{name:name,exit:exitCode,reason:reason}}'
   ```

   | `exitCode` / `stoppedReason` | 疑うもの | 追加で必要な打ち手 |
   |---|---|---|
   | `1` + `Essential container in task exited` | uid 不一致 / `${env.*}` 未解決 | 15-(a) / 15-(d) |
   | `137` | メモリ hard limit | **ビルド時適用 (①)** でブートを 1 回に戻す |
   | `143` / `Task failed ELB health checks` | 起動時間の倍増 | **ビルド時適用 (①)** でブートを 1 回に戻す |

3. **137 / 143 だった場合のみ**、最小対応から一段上げて
   `APPLY_TLS_CONFIG_AT_BUILD=true` (ビルド時適用) まで入れる。
