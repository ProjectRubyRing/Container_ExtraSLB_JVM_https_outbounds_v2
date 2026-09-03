# 「最短の打ち手」は本当に安全か — 論理的検証

対象:

```dockerfile
RUN rm -rf "${JBOSS_HOME}/standalone/configuration/standalone_xml_history"
```

前提構成: `readonlyRootFilesystem=false` / `standalone/configuration` にボリューム・tmpfs 無し /
`configuration-seed` の書き戻しは有効。
背景と全体像は [standalone-xml-history-ecs-vs-compose.md](./standalone-xml-history-ecs-vs-compose.md)
の 13〜18 章を参照。

---

## 0. 結論 — 先に答える

| 問い | 答え |
|---|---|
| **この 1 行は安全か (壊さないか)** | **はい。ただし 5 章の 4 条件を満たす場合に限る。** 条件はいずれも 1 コマンドで事前確認できる |
| **この 1 行で WFLYCTL0056 / 0414 は消えるか** | **はい。原理的に消える** (3 章で証明) |
| **この 1 行で「ECS だけ異常終了する」事象は直るか** | **❌ 保証できない。むしろ直らない可能性のほうが高い** (4 章) |
| **では「絶対に大丈夫」か** | **「変更として安全」という意味では YES。「これで直る」という意味では NO。** |

> **前提**: 本書の安全性の証明 (2 章) と効果の証明 (3 章) は、
> WildFly のソースと Linux カーネル公式ドキュメントという**一次情報から導いており確実**である。
> 一方「そもそもイメージに履歴が焼き込まれているか」は**未確認の仮説**であり、
> 4-4 で必ず確認すること。確認済み / 未確認の全体像は
> [standalone-xml-history-ecs-vs-compose.md の 19 章](./standalone-xml-history-ecs-vs-compose.md#19-検証状況--何を確認し何を確認していないか) を参照。

> ### ⚠ 前回の説明の訂正
> 前回「最短の打ち手」と表現したが、これは
> **「最も安全で、最も少ない変更で、確実に効果が確定している一手」**という意味であって、
> **「これだけで異常終了が直る」という意味ではない。**
> 現行構成では WFLYCTL0414 は ECS でも Compose でも同じ理由 (EXDEV) で出るため、
> **この 1 行はノイズを消すだけで、ECS と Compose の差を説明しない。**
> 異常終了の原因特定は
> [15 章の手順 0 (`describe-tasks` の `stoppedReason` / `exitCode`)](./standalone-xml-history-ecs-vs-compose.md#15-この構成でecs-だけ異常終了するときの切り分け)
> から始める必要がある。両者は**並行して**進めるべきものであり、
> この 1 行は「切り分けの邪魔になるノイズを消す」という位置づけが正しい。

---

## 1. この 1 行が変えるものを厳密に定義する

### 1-1. 変わるもの

| | 変更前 | 変更後 |
|---|---|---|
| イメージ内の `configuration/standalone_xml_history` | **存在する**(※) | **存在しない** |
| コンテナ起動直後の同ディレクトリ | イメージ由来 = overlayfs の **merged / lower** ディレクトリ | 存在しない → 起動時に **upper 専用** として新規作成される |
| イメージサイズ | — | **変わらない** (whiteout が増えるだけで下位レイヤのデータは残る) |

※ 「存在する」のは**イメージビルド中に一度でもサーバ / `embed-server` を起動している場合**。
起動していなければこの 1 行は **no-op** であり、その事実自体が重要な診断情報になる (4-4)。

### 1-2. 変わらないもの

* `standalone.xml` / `logging.properties` などの設定ファイル本体 — **一切触らない**
* `configuration` ディレクトリ自身の所有者・パーミッション
* `configuration-seed` の内容 — seed 方式の Dockerfile は元々
  `rm -rf "${JBOSS_CONF_SEED_DIR}/standalone_xml_history"` で seed から除外済み
* 実行時の JBoss の挙動 — 履歴ディレクトリは**毎ブート自動生成される**もの (2 章)

### 1-3. ロールバック

**1 行を消して再ビルドするだけ。** データマイグレーションも状態の巻き戻しも不要。
イメージは immutable なので、旧イメージのタグへ戻せば完全に元に戻る。

---

## 2. 「削除しても壊れない」ことの証明

`standalone_xml_history` は **JBoss が毎ブート自分で作り直すディレクトリ**である。
以下、WildFly Core の実コードで「無くても壊れない」ことを網羅的に確認する。

### 2-1. 履歴ディレクトリは無条件に再生成される

```java
// ConfigurationFile#createHistoryDirectory()  (successfulBoot() から呼ばれる)
private void createHistoryDirectory() throws IOException {
    mkdir(this.historyRoot);          // configuration/standalone_xml_history
    mkdir(this.snapshotsDirectory);   // .../snapshot
    if (currentHistory.exists()) {    // ← 無ければこのブロックは丸ごとスキップ
        ...                           //    (rename も 30 日クリーンアップも走らない)
    }
    currentHistory.mkdir();           // .../current
    if (!currentHistory.exists()) {
        throw ControllerLogger.ROOT_LOGGER.cannotCreate(currentHistory.getAbsolutePath());
    }
}

private File mkdir(final File dir) {
    if (!dir.exists()) {
        if (!dir.mkdir()) {                                    // ← 1 階層だけ作る
            throw ControllerLogger.ROOT_LOGGER.cannotCreate(historyRoot.getAbsolutePath());
        }
    } else if (!dir.isDirectory()) { ... }
    return dir;
}
```

* `mkdir()` は **1 階層のみ**作るため、親が存在している必要がある。
  親は `configuration` であり、**これは常に存在する** (無ければそもそもサーバは起動できない)。
* `historyRoot` → `snapshotsDirectory` → `currentHistory` の順に作るので、
  各時点で親は必ず存在している。
* `currentHistory.exists()` が false なので **★ rename ブロックには入らない**。
  → **WFLYCTL0056 / 0414 は構造的に発生し得ない。**

**結論: 「無い状態」は JBoss にとって完全に想定内であり、むしろ最も素直な初期状態である。**

### 2-2. ブート経路が履歴ディレクトリを参照する箇所 — 全件確認

`-c` (= `SERVER_CONFIG`) の値によって、起動時の設定ファイル解決が履歴を見に行くことがある。
**全経路を洗い出すと次の 5 箇所だけ**である。

| 呼び出し元 | 条件 | 履歴が無いとどうなるか |
|---|---|---|
| `determineMainFile` → `findMainFileFromBackupSuffix(historyRoot, …)` | `-c` が **`last` / `initial` / `boot`** | ❌ **例外を投げる** (`configurationFileNotFound`) |
| `determineMainFile` → `findMainFileFromBackupSuffix(currentHistory, …)` | `-c` が **`v1`, `v2`, …** | ❌ **例外を投げる** |
| `determineMainFile` → `findMainFileFromSnapshotPrefix` | 常に (フォールバック) | ✅ `snapshotsDirectory.exists()` で**ガード済み** → `null` を返して次へ進む |
| `determineBootFile` → `findSnapshotWithPrefix(name, false)` | 常に (フォールバック) | ✅ `exists()` ガード + `errorIfNoFiles=false` → `null` を返して次へ進む |
| `successfulBoot` → `addSuffixToFile(historyRoot, …)` | 常に | ✅ 単なる `File` 生成。直前の `createHistoryDirectory()` で親は作成済み |

該当コード (`exists()` ガードの実在確認):

```java
private String findMainFileFromSnapshotPrefix(final String prefix) {
    File[] files = null;
    if (snapshotsDirectory.exists() && snapshotsDirectory.isDirectory()) {   // ← ガード
        files = snapshotsDirectory.listFiles(...);
    }
    if (files == null || files.length == 0) {
        return null;                                                          // ← 安全に null
    }
    ...
}

private File findSnapshotWithPrefix(final String prefix, boolean errorIfNoFiles) {
    List<String> names = new ArrayList<String>();
    if (snapshotsDirectory.exists() && snapshotsDirectory.isDirectory()) {   // ← ガード
        for (String curr : snapshotsDirectory.list()) { ... }
    }
    if (names.isEmpty() && errorIfNoFiles) { throw ... }                     // ← false なので投げない
    ...
    return !names.isEmpty() ? new File(snapshotsDirectory, names.get(0)) : null;
}
```

**`-c standalone.xml` (既定) のときの実際の経路をトレースすると:**

```
determineMainFile(rawName="standalone.xml", name="standalone.xml")
  ├ name は "last"/"initial"/"boot" ではない          → 履歴を見ない
  ├ VERSION_PATTERN (v\d+) にマッチしない              → 履歴を見ない
  ├ findMainFileFromSnapshotPrefix("standalone.xml")  → snapshot 無し → null (安全)
  └ new File(configurationDir, "standalone.xml").exists() == true
        → mainName = "standalone.xml"                 ✅ 履歴に一切依存しない

determineBootFile(configurationDir, "standalone.xml")
  ├ "last"/"initial"/"boot" ではない                   → 履歴を見ない
  ├ VERSION_PATTERN にマッチしない                     → 履歴を見ない
  ├ findSnapshotWithPrefix("standalone.xml", false)   → null (安全)
  └ directoryFile.exists() == true → 採用             ✅ 履歴に一切依存しない
```

**結論: `SERVER_CONFIG` が `last` / `initial` / `boot` / `vN` / スナップショット名でない限り、
ブート経路は履歴ディレクトリに一切依存しない。**
これが 5 章の必須条件 C1 になる。

### 2-3. 失われる情報とその評価

| 失われるもの | 評価 |
|---|---|
| `standalone.initial.xml` (ビルド時点の内容) | **初回ブートで再生成される。** 内容は「初回ブートが読んだ `standalone.xml`」= ビルド完了時点の内容と**同一**。ビルド時に Elytron 設定を適用してあれば意味論も完全に一致する |
| `standalone.boot.xml` / `standalone.last.xml` | 同上。毎ブート上書きされるファイルなので、そもそも「ビルド時の値」に意味は無い |
| `current/standalone.vN.xml` | **ビルド時の CLI 実行によって生まれた中間状態**であり、運用上の価値は無い。同じ内容は `configuration-seed/standalone.xml` またはイメージ履歴 (`docker history`) から取得できる |
| `<yyyyMMdd-HHmmssSSS>/` | 同上。ビルド時のブート由来 |
| `snapshot/*.xml` | **明示的に `:take-snapshot` した場合のみ存在する。** ビルド時に意図的に取っていない限り空 → 5 章の条件 C2 で確認 |

**運用上の履歴 (= 実際に稼働したサーバの設定変更履歴) は 1 件も失われない。**
現行構成ではボリュームを当てていないため、そもそも**履歴はタスク終了時に毎回消える**。
イメージ内の履歴は「ビルドマシン上の一度きりのブート」の記録でしかない。

### 2-4. 冪等性・再現性

* `rm -rf` は対象が無くても成功する → **ビルドは常に成功する**
* 何度ビルドしても結果は同じ
* ビルドキャッシュの挙動も変わらない (単なる 1 レイヤ追加)

---

## 3. 「WFLYCTL0056 / 0414 が消える」ことの証明

### 3-1. 根拠 — Linux カーネル公式ドキュメント

`Documentation/filesystems/overlayfs.rst` (Renaming directories) より:

> **When renaming a directory from the lower layer or a merged directory**, overlayfs offers two approaches:
> - **return EXDEV error**: this error is returned by `rename(2)` when trying to move a file or
>   directory across filesystem boundaries. **(default behaviour)**
> - with **`redirect_dir`** enabled: the directory will be copied up (but not the contents)…

> A directory is made **opaque** by setting the xattr `trusted.overlay.opaque` to `"y"`.
> Where the upper filesystem contains an opaque directory,
> **any directory in the lower filesystem with the same name is ignored.**

`redirect_dir` は Docker / containerd の既定では **off**。

### 3-2. 状態遷移

```
【変更前】
  イメージ layer N-1 : configuration/standalone_xml_history/current/standalone.v1.xml
  コンテナ upper     : (seed の cp -R でファイルだけコピーアップされる)

  → current は「lower を持つディレクトリ」= merged
  → ovl_rename() が EXDEV を返す
  → JDK が mkdir+rmdir にフォールバック → rmdir が ENOTEMPTY
  → DirectoryNotEmptyException → WFLYCTL0056 + WFLYCTL0414   ★毎起動・毎 :reload 必発

【変更後】
  イメージ layer N   : standalone_xml_history に対する whiteout
  コンテナ起動時      : lookup が whiteout で停止 → パスは「存在しない」
  mkdir(standalone_xml_history) → upper に新規作成 (lower 対応物なし)
  mkdir(snapshot) / mkdir(current) → いずれも upper 専用

  → current は pure upper
  → ovl_can_move() が true → rename(2) が成功
  → そもそも current は空なので ★(A) の判定で rename 自体が呼ばれない
```

**二重に安全**である点が重要:

1. `current` が**空**なので `createHistoryDirectory()` は rename を呼ばない (★(A) の早期リターン)
2. 万一 `current` が非空になっても (seed が履歴を含む場合など)、
   pure upper なので **rename が成功する**

### 3-3. 「コピーアップされれば直る」は誤り — なぜ削除が必要なのか

よくある誤解として「どうせ seed の `cp -R` で上書きされるから upper になるはず」があるが、**これは成立しない**。

* コピーアップは「upper **にも**実体を作る」操作であり、**lower の対応物は消えない**
* `ovl_type_merge()` は「upper と lower の**両方**を持つ」状態を merged と判定する
* したがってコピーアップ後も merged のままで、**`rename` は永久に EXDEV を返し続ける**

**merged 状態から抜ける方法は「削除して作り直す」しか無い** (whiteout → opaque)。
これがイメージ側で `rm -rf` する理由であり、
起動時に救済する場合も `entrypoint.sh` の `recreate_history()` が
`rm -rf` → `mkdir` の順で同じことをしている理由である。

### 3-4. 論理的帰結

> **前提**: イメージに `standalone_xml_history` が存在する。
> **操作**: ビルド時に削除する。
> **帰結**: 実行時に生成される履歴ツリーは pure upper となり、
> `rename(2)` が成立する。かつ初回ブート時点で `current` は空なので rename 自体が発生しない。
> **∴ WFLYCTL0056 / WFLYCTL0414 は発生し得ない。**

この帰結は**環境に依存しない** (ECS / Compose / EC2 / ローカルすべてで同じ)。
overlayfs の仕様と WildFly のコードだけから導かれるため、確実である。

---

## 4. ★ しかし「異常終了が直る」とは言えない

ここが本質的な注意点である。

### 4-1. WFLYCTL0414 はサーバを落とさない

```java
@LogMessage(level = Level.WARN)                                   // ← WARN
@Message(id = 414, value = "Could not create a timestamped backup of current history dir %s, …")
void couldNotCreateHistoricalBackup(String currentHistoryDir);
```

`createHistoryDirectory()` は WARN を出した後、`currentHistory.mkdir()` へ進み、
`current` は既に存在するので `exists()` が true → **例外を投げずに正常復帰する**。
ブートを落としているのは、その後の

```java
FilePersistenceUtils.copyFile(copySource, initial / lastFile / boot);
} catch (IOException e) {
    throw ControllerLogger.ROOT_LOGGER.failedToCreateConfigurationBackup(e, bootFile);  // WFLYCTL0082
}
```

であり、**これは「`standalone_xml_history` にファイルを書けるか」という別問題**である。
overlayfs 上では書ける (コピーアップされる) ので、**EXDEV は WFLYCTL0082 を引き起こさない。**

### 4-2. 現行構成では EXDEV は ECS でも Compose でも起きる

ボリュームも `readonlyRootFilesystem` も無いため、
`configuration` の実体は**両環境とも同じ overlayfs** である。
同じイメージを使う以上、lower レイヤの構成も同一。

> **∴ EXDEV は「ECS だけ異常終了する」という差を説明できない。**
> この 1 行は「両環境に等しく出ているノイズ」を消すだけである。

### 4-3. したがってこの 1 行の正しい位置づけ

| | |
|---|---|
| **やること** | 両環境に出ている WFLYCTL0056/0414 を確実に消す |
| **やらないこと** | ECS 固有の異常終了を直す |
| **価値** | ① ログから既知のノイズが消え、**真の原因が読みやすくなる** ② `:reload` 時のローテーションも通るようになる ③ 副作用がほぼ無いので、切り分けと並行して安全に入れられる |

**異常終了の原因特定は必ず別途行うこと。**
[15 章の手順 0](./standalone-xml-history-ecs-vs-compose.md#15-この構成でecs-だけ異常終了するときの切り分け):

```bash
aws ecs describe-tasks --cluster <cluster> --tasks <task-arn> \
  --query 'tasks[0].{stopped:stoppedReason,containers:containers[].{name:name,exit:exitCode,reason:reason}}'
```

| `exitCode` / `stoppedReason` | 疑うもの |
|---|---|
| `1` + `Essential container in task exited` | タスク定義の `user` 指定による uid 不一致 (15-a) / `${env.*}` 未解決 (15-d) |
| `137` | メモリ hard limit (15-c) |
| `143` / `Task failed ELB health checks` | 起動時間の倍増でヘルスチェック超過 (15-b) |

### 4-4. 反証可能な判定 — 適用前に必ずこれを見る

**この 1 行を入れる前に、イメージに履歴が本当にあるかを確認する。**

```bash
# $JBOSS_HOME はコンテナ内で展開させる (ホスト側では未定義なので sh -c で包む)
docker run --rm --entrypoint sh <image> -c \
  'ls -la "$JBOSS_HOME/standalone/configuration"' | grep standalone_xml_history
```

| 結果 | 論理的帰結 |
|---|---|
| **ヒットする** | EXDEV 説と整合。この 1 行は有効 (ノイズは消える)。ただし異常終了は別原因 → 15 章へ |
| **ヒットしない** | **この 1 行は no-op であり、何も変わらない。** かつ、履歴が実行時に生成されるなら pure upper なので **EXDEV は起き得ない** → 出ている WFLYCTL0414 の原因は **EACCES / EPERM (所有者・権限)** に絞られる → **15-(a) が本命**。この場合こそ ECS だけ落ちる説明が付く |

さらに確実なのは、ログの WFLYCTL0414 の**直前**にある WFLYCTL0056 の原因例外を見ること。

| 原因例外 | 意味 | この 1 行の効果 |
|---|---|---|
| `DirectoryNotEmptyException` | EXDEV (overlayfs) | ✅ 消える |
| `AccessDeniedException` | EACCES / EPERM (所有者不一致) | ❌ **効かない** → 15-(a) の対処が必要 |
| `FileSystemException: Read-only file system` | EROFS | ❌ 効かない (現行構成では発生しないはず) |

---

## 5. この 1 行が壊し得る唯一の現実的ケース (と事前確認)

安全性の根拠は 2 章で示したが、**次の 4 条件を満たすことだけは確認すること。**
いずれも 1 コマンドで確認できる。

### C1. `SERVER_CONFIG` が `last` / `initial` / `boot` / `vN` / スナップショット名でない ★唯一の破壊ケース

2-2 のとおり、これらを `-c` に渡すと `findMainFileFromBackupSuffix()` が
**履歴ディレクトリを必須とし、無ければ例外を投げる**。

```java
if (files == null || files.length == 0) {
    throw ControllerLogger.ROOT_LOGGER.configurationFileNotFound(suffix, searchDir);  // ← 落ちる
}
```

確認:

```bash
# タスク定義 / compose / Dockerfile ENV のいずれにも last/initial/boot/vN が無いこと
aws ecs describe-task-definition --task-definition <td> \
  --query "taskDefinition.containerDefinitions[].environment[?name=='SERVER_CONFIG']"
grep -rn 'SERVER_CONFIG' docker-compose*.yml */Dockerfile 2>/dev/null
```

→ 未設定か `standalone.xml` (または通常の `*.xml`) なら **問題なし**。

### C2. ビルド時に意図的なスナップショットを焼き込んでいない

```bash
docker run --rm --entrypoint sh <image> -c \
  'ls -la "$JBOSS_HOME/standalone/configuration/standalone_xml_history/snapshot"'
```

→ 空 (または存在しない) なら **問題なし**。
中身がある場合は、削除前に `docker cp` で退避するか、`snapshot` だけ残す形に変更する。

```dockerfile
# snapshot を残したい場合の代替
RUN rm -rf "${JBOSS_HOME}/standalone/configuration/standalone_xml_history/current" \
           "${JBOSS_HOME}/standalone/configuration/standalone_xml_history"/2*[0-9]
```

> ただし **この代替では `standalone_xml_history` 自体が merged のまま残るため、
> EXDEV は解消しない。** snapshot を残したい場合は、
> 起動時の `EXTRASLB_HISTORY_AUTO_RECREATE=true` (既定) による作り直しに任せるほうがよい。

### C3. RUN の配置が「configuration に触れる最後の RUN」の後ろ

**後続の RUN が再び `embed-server` / `standalone.sh` を実行すると履歴が復活する。**
front / back の Dockerfile 側で CLI を追加している場合は、そちら側にも同じ行が必要。

```dockerfile
JBoss EAP 導入
  └→ ビルド時 CLI 設定 (データソース等も含めて全部)
       └→ ★ rm -rf standalone_xml_history        ← configuration に触れる最後
            └→ configuration-seed の退避
                 └→ standalone/log のシンボリックリンク化
```

確認 (ビルド後の最終イメージで):

```bash
docker run --rm --entrypoint sh <image> -c \
  'ls -d "$JBOSS_HOME/standalone/configuration/standalone_xml_history" 2>/dev/null \
   && echo "NG: 復活している" || echo "OK"'
```

### C4. `configuration-seed` が履歴を含んでいない

含んでいると、起動時の `cp -R seed/. configuration/` で `current` が非空になる。
**壊れはしない** (upper 専用なので rename は成功する) が、無駄なローテーションが毎起動走る。

```bash
docker run --rm --entrypoint sh <image> -c \
  'ls -la "$JBOSS_HOME/standalone/configuration-seed"' | grep standalone_xml_history \
  && echo "seed に履歴が含まれている (除外を推奨)" || echo "OK"
```

### C5 (参考). イメージサイズは減らない

`rm -rf` は whiteout を作るだけで、下位レイヤのデータは残る。
サイズ削減が目的なら履歴を作らないビルド手順にするか、
マルチステージ / `--squash` を使う。**機能面には影響しない。**

---

## 6. 適用手順 (コピペ可能)

```bash
IMAGE=<現行イメージ>

# ── 適用前チェック ───────────────────────────────────────────────
echo "== 履歴がイメージにあるか (無ければこの 1 行は no-op) =="
docker run --rm --entrypoint sh "$IMAGE" -c \
  'ls -la "$JBOSS_HOME/standalone/configuration"' | grep standalone_xml_history || echo "(無し)"

echo "== C1: SERVER_CONFIG =="
docker run --rm --entrypoint sh "$IMAGE" -c 'echo "${SERVER_CONFIG:-(未設定=standalone.xml)}"'

echo "== C2: snapshot =="
docker run --rm --entrypoint sh "$IMAGE" -c \
  'ls -la "$JBOSS_HOME/standalone/configuration/standalone_xml_history/snapshot"' 2>/dev/null || echo "(無し)"

echo "== C4: seed に履歴が含まれていないか =="
docker run --rm --entrypoint sh "$IMAGE" -c \
  'ls -la "$JBOSS_HOME/standalone/configuration-seed"' 2>/dev/null | grep standalone_xml_history || echo "(含まれていない)"
```

```dockerfile
# ── 適用 (configuration に触れる最後の RUN の直後に置く) ──────────
RUN rm -rf "${JBOSS_HOME}/standalone/configuration/standalone_xml_history"
```

```bash
# ── 適用後チェック ───────────────────────────────────────────────
docker run --rm --entrypoint sh "$IMAGE" -c \
  'ls -d "$JBOSS_HOME/standalone/configuration/standalone_xml_history" 2>/dev/null \
   && echo "NG: C3 違反 (後続 RUN で復活)" || echo "OK: 履歴なし"'

# 起動して、履歴が正しく再生成され、エラーが出ないこと
docker run --rm "$IMAGE" 2>&1 | tee /tmp/boot.log | head -40
grep -E 'WFLYCTL0056|WFLYCTL0414|WFLYCTL0082' /tmp/boot.log && echo "NG" || echo "OK: 履歴エラー無し"
grep -E 'rename 検査' /tmp/boot.log        # → "OK" が出ること
```

---

## 7. 「絶対に大丈夫」にするための最小セット

この 1 行だけでは 4 章のとおり**異常終了の解決を保証できない**。
確実にするには次の順で積む。

| 段 | 施策 | 確定できること | 変更箇所 |
|:--:|---|---|---|
| **0** | `describe-tasks` で `stoppedReason` / `exitCode` を確認 | **異常終了の系統が確定する。これをやらないと以降はすべて推測** | — (調査のみ) |
| **1** | `rm -rf standalone_xml_history` (本書の 1 行) | WFLYCTL0056/0414 が消える。ログが読めるようになる | Dockerfile 1 行 |
| **2** | タスク定義の `user` を外す / `chown -R <uid>:<gid> configuration` | 15-(a) EACCES 由来の WFLYCTL0082 が消える | タスク定義 or Dockerfile |
| **3** | Elytron 設定をビルド時適用 (`EXTRASLB_TLS_CONFIG_MODE=auto` が CLI をスキップ) | 起動時間・メモリピークが対応前の水準に戻る → 15-(b)(c) が消える | Dockerfile |
| **4** | `CONFIG_SEED_MODE=skip` (ボリューム未使用の間) | 段 3 の効果が毎起動巻き戻されるのを防ぐ | タスク定義 |
| **5** | `entrypoint.sh` の preflight (実装済み) | 権限問題が WFLYCTL0082 ではなく **`FATAL: … に書き込めません`** として出る | (対応済み) |

**段 0 と段 1 は同時に着手してよい。**
段 1 は副作用がほぼ無く、段 0 の調査を邪魔しないどころか、
ログからノイズを消して調査を助ける。

---

## 8. まとめ

```
Q. 最短の打ち手 (rm -rf standalone_xml_history) は絶対に大丈夫か？

A1. 「壊さないか」    → はい。C1〜C4 を確認すれば安全。ロールバックは 1 行削除のみ。
                        JBoss は履歴ディレクトリを毎ブート自動生成するため、
                        無い状態は完全に想定内 (2 章)。

A2. 「効果があるか」  → WFLYCTL0056/0414 に対しては、原理的に確実に効く (3 章)。
                        overlayfs の仕様と WildFly のコードだけから導ける。

A3. 「異常終了が直るか」→ ❌ 保証できない。現行構成では EXDEV は ECS/Compose 両方で
                        起きているため、両者の差を説明しない (4 章)。
                        原因特定は describe-tasks の stoppedReason / exitCode から。

∴ 「安全に入れてよい一手。ただしこれを入れたから直る、とは考えないこと。」
```

**唯一の本当の破壊ケースは C1** (`SERVER_CONFIG` に `last` / `initial` / `boot` / `vN` を指定している)。
これに該当しないことだけは、適用前に必ず確認すること。
