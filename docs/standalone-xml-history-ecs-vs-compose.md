# standalone_xml_history のローテーション失敗 — ECS だけ異常終了する根本原因と修正

対象症状:

> `entrypoint.sh` の対応 (起動時に JBoss CLI で Elytron を設定) を
> `configuration-seed` の対応 (別リポジトリ `ECS_EFS_Dockerfile_Symboliclink_lite`) と
> **一緒に入れた**ところ、ECS タスクで
>
> ```
> 現在の履歴ディレクトリ - /opt/jboss-eap/standalone/configuration/standalone_xml_history/current
> のタイムスタンプ付きバックアップを作成できませんでした。
> したがって前の起動バージョンがまだ含まれている可能性があります。
> ```
>
> が出力されて **異常終了**する。
> この対応を入れる前も history の保存には失敗していたが、起動自体はしていた。
> **同じ構成を Compose で動かすと、同じように history の保存には失敗するのに起動してしまう。**

---

## 0. 結論 (先に 3 行)

1. **引き金**は `entrypoint.sh` の `embed-server` である。これが「1 回目の設定ブートストラップ」になり、
   続く `standalone.sh` の本ブートが「2 回目」になったことで、
   **毎起動 `standalone_xml_history/current` の "ディレクトリ rename" が必ず走る**ようになった。
2. 引用されているメッセージ (**WFLYCTL0414**) は **WARN であり、これ自体はサーバを落とさない**。
   落としているのは**その直後**に走る `successfulBoot()` の `copyFile()` (**WFLYCTL0082**) である。
3. **Compose と ECS の差は「rename が失敗した理由 (errno) の違い」**。
   overlayfs のレイヤ跨ぎ (`EXDEV`) が理由なら親ディレクトリは書けるので後続は成功し**起動する (= Compose)**。
   親ディレクトリに書けない (`EACCES`) / read-only (`EROFS`) が理由なら後続も同じ理由で失敗し
   **異常終了する (= ECS)**。同じ WARN 行でも、原因の errno が違う。

修正は「rename を発生させない」+「所有権を実行ユーザーに固定する」+「起動あたりのブートストラップを 1 回に戻す」の 3 段構え。
実装箇所は [8 章](#8-どこを修正実装したか) を参照。

> **本ドキュメントの「確認済み」と「仮説」の区別は [19 章](#19-検証状況--何を確認し何を確認していないか) にまとめてある。**
> WildFly のコード・カーネル仕様・スクリプトの動作は一次情報で確認済みだが、
> **実イメージ / 実 ECS タスクでの再現は行えていない** (この環境で Docker が使えないため)。
> 実環境で最初に取るべき 5 つの読み取りコマンドは [19-4](#19-4-実環境で最初にやること-優先順) にある。

> ### ⚠ 構成によって「3.」の説明が変わる — まず自分の構成を確認すること
>
> **0〜12 章は `readonlyRootFilesystem=true` + `configuration` にタスクローカルボリューム
> を当てている構成**を前提にしている。
>
> **`readonlyRootFilesystem=false` でボリュームも tmpfs も当てず、
> `configuration-seed` だけ有効にしている構成の場合は、
> [13 章以降の「構成別 追補」](#構成別-追補現行構成--readonlyrootfilesystemfalse--ボリューム無し--seed-有効) を読むこと。**
> その構成では ECS と Compose のファイルシステム挙動は同一になるため、
> 上記「3.」の errno による分岐は当てはまらず、
> **原因は overlayfs の merged ディレクトリ問題 (13-2) と、
> ファイルシステム以外の ECS 固有要因 (15 章)** に分かれる。
> 対処法の有効性は [14 章のマトリクス](#14-これまでの対処法は有効か--有効性マトリクス) にまとめてある。
>
> なお 16-1 で「最短の打ち手」として挙げている
> `rm -rf .../standalone_xml_history` の 1 行については、
> **それが安全か / それだけで直るのか**を独立に検証した
> [shortest-fix-safety-analysis.md](./shortest-fix-safety-analysis.md) がある。
> 結論だけ先に言うと **「変更として安全。ただしこれだけで異常終了が直る保証は無い」**。

---

## 1. 前提 — 2 つの対応がそれぞれ何をしたのか

| 対応 | 何をするか | 副作用 |
|---|---|---|
| **本リポジトリ `base/scripts/entrypoint.sh`** | 起動時に `jboss-cli.sh --file=` で `embed-server` を起動し、Elytron の key-store / trust-manager / client-ssl-context を `standalone.xml` へ書き込む | **コンテナ 1 起動あたりの「設定ブートストラップ」が 2 回になる** |
| **`configuration-seed` 方式 (別リポジトリ)** | `readonlyRootFilesystem=true` 対応。ビルド時に `configuration` を `configuration-seed` へ退避し、起動時に空のタスクローカルボリュームへ `cp -R` で書き戻す | **`configuration` の物理的な実体が「イメージの overlayfs」から「ECS のボリューム」へ変わる** |

この 2 つは単独ではどちらも動く。**組み合わさったときだけ**、
「毎起動必ず走るようになった fragile な操作 (rename)」が
「環境ごとに実体の違うファイルシステム」の上で実行されることになり、環境差が表面化する。

### 1-1. `embed-server` が configuration に何を書くのか

`embed-server` は CLI 用の軽量サーバではなく、**同一 JVM 内で本物の WildFly コントローラをブートする**。
したがって設定ファイルの履歴処理も本ブートと完全に同じものが走る。CLI 実行後の `configuration` は以下になる。

```
configuration/
  standalone.xml                                  <- Elytron 設定が入った「新しい」内容
  standalone_xml_history/
    current/
      standalone.v1.xml                           <- ★ CLI 適用「前」の内容 (backup() が move した)
    snapshot/
    standalone.initial.xml                        <- successfulBoot() が作る
    standalone.boot.xml
    standalone.last.xml
```

`current/standalone.v1.xml` が作られるのは `ConfigurationFile#backup()` が
`standalone.xml` を **バージョン付きファイルへ move** してから新しい内容を書き直すため。

```java
// wildfly-core: controller/.../persistence/ConfigurationFile.java
void backup() throws ConfigurationPersistenceException {
    ...
    moveFile(mainFile, getVersionedFile(mainFile));   // standalone.xml -> current/standalone.vN.xml
    ...
}
private void moveFile(final File file, final File backup) throws IOException {
    Files.move(file.toPath(), backup.toPath(), StandardCopyOption.REPLACE_EXISTING);
}
```

**この対応を入れる前は `current` が空 (または存在しない) のまま `standalone.sh` に到達していた。**
入れた後は **必ず中身が入った状態**で本ブートを迎える。ここが分水嶺である。

---

## 2. WildFly Core の実コード — 起動時に何が起きるか

以下は `wildfly-core` の `controller/src/main/java/org/jboss/as/controller/persistence/ConfigurationFile.java` から。
（JBoss EAP 8.x / 7.4 も同一ロジック）

### 2-1. 履歴ディレクトリの作成とローテーション

```java
private void createHistoryDirectory() throws IOException {
    mkdir(this.historyRoot);          // configuration/standalone_xml_history
    mkdir(this.snapshotsDirectory);   // configuration/standalone_xml_history/snapshot
    if (currentHistory.exists()) {
        if (!currentHistory.isDirectory()) {
            throw ControllerLogger.ROOT_LOGGER.notADirectory(currentHistory.getAbsolutePath());
        }

        //Copy any existing history directory to a timestamped backup directory
        Date date = new Date();
        File[] currentHistoryFiles = currentHistory.listFiles();
        if (currentHistoryFiles != null && currentHistoryFiles.length > 0) {   // ★(A) 空なら何もしない
            String backupName = getTimeStamp(date);
            File old = new File(historyRoot, backupName);
            if (!forcedMove(currentHistory.toPath(), old.toPath())) {          // ★(B) ディレクトリ rename
                if (old.exists()) {
                    date = new Date(date.getTime() + 100);
                    backupName = getTimeStamp(date);
                    old = new File(historyRoot, backupName);
                    if (!forcedMove(currentHistory.toPath(), old.toPath())) {
                        ControllerLogger.ROOT_LOGGER
                            .couldNotCreateHistoricalBackup(currentHistory.getAbsolutePath());  // ★(C) WFLYCTL0414
                    }
                } else {
                    ControllerLogger.ROOT_LOGGER
                        .couldNotCreateHistoricalBackup(currentHistory.getAbsolutePath());      // ★(C) WFLYCTL0414
                }
            }
        }
        ... // 30 日より古い <timestamp> ディレクトリの削除 (失敗してもログのみ)
    }

    currentHistory.mkdir();
    if (!currentHistory.exists()) {
        throw ControllerLogger.ROOT_LOGGER.cannotCreate(currentHistory.getAbsolutePath());      // WFLYCTL0051
    }
}

private static boolean forcedMove(Path from, Path to) {
    try {
        Files.move(from, to, StandardCopyOption.REPLACE_EXISTING);
        return true;
    } catch (IOException e) {
        ControllerLogger.ROOT_LOGGER.cannotRename(e, from, to);   // ★(D) WFLYCTL0056 (ERROR) 原因の errno はここ
        return false;
    }
}
```

**★(A) が最重要**: `current` が**空なら rename は一切実行されない**。
本修正はここを利用している (7-2)。

### 2-2. 実際にブートを落としているのはここ

```java
void successfulBoot() throws ConfigurationPersistenceException {
    ...
    try {
        if (!bootFile.equals(copySource)) {
            FilePersistenceUtils.copyFile(bootFile, copySource);
        }

        createHistoryDirectory();                       // ← ここで WFLYCTL0056 / 0414 が出る (WARN 止まり)

        final File historyBase = new File(historyRoot, mainFile.getName());
        lastFile          = addSuffixToFile(historyBase, LAST);      // standalone.last.xml
        final File boot   = addSuffixToFile(historyBase, BOOT);      // standalone.boot.xml
        final File initial= addSuffixToFile(historyBase, INITIAL);   // standalone.initial.xml

        if (!initial.exists()) {
            FilePersistenceUtils.copyFile(copySource, initial);      // ★(E)
        }
        FilePersistenceUtils.copyFile(copySource, lastFile);         // ★(E)
        FilePersistenceUtils.copyFile(copySource, boot);             // ★(E)
    } catch (IOException e) {
        throw ControllerLogger.ROOT_LOGGER
            .failedToCreateConfigurationBackup(e, bootFile);         // ★(F) WFLYCTL0082 → ブート失敗
    }
    ...
}
```

```java
// FilePersistenceUtils
static void copyFile(final File file, final File backup) throws IOException {
    Files.copy(file.toPath(), backup.toPath(),
               StandardCopyOption.COPY_ATTRIBUTES, StandardCopyOption.REPLACE_EXISTING);
}
```

★(E) の 3 つの `copyFile` は **`standalone_xml_history/` 直下にファイルを作る**。
`REPLACE_EXISTING` なので **既存ファイルの unlink → 新規 create** が走る。
つまり**親ディレクトリ `standalone_xml_history` への書き込み権限が必須**。

### 2-3. ログ ID 早見表

| ID | レベル | メッセージ | 意味 |
|---|---|---|---|
| **WFLYCTL0056** | **ERROR** | `Could not rename %s to %s` | ★ **原因の `IOException` (errno) がここに出る。最重要の手掛かり** |
| **WFLYCTL0414** | **WARN** | 現在の履歴ディレクトリ - … のタイムスタンプ付きバックアップを作成できませんでした | **今回引用されたメッセージ。これ自体は落とさない** |
| **WFLYCTL0082** | — (`ConfigurationPersistenceException`) | `Failed to create backup copies of configuration file %s` | ★ **実際にブートを落としているのはこれ** |
| WFLYCTL0051 | — (`IllegalStateException`) | `Could not create %s` | `standalone_xml_history` / `current` 自体を作れなかった場合 |

> **ここが誤解の出発点**: 目に見える日本語メッセージが WFLYCTL0414 なので
> 「このエラーで異常終了した」と読めてしまうが、**WFLYCTL0414 は WARN** である。
> 異常終了の直接原因は必ずその後ろの **WFLYCTL0082** (または WFLYCTL0051)。

---

## 3. 根本原因

### 3-1. 引き金 (両環境で共通) — 「設定ブートストラップが 2 回」になった

```
【修正前】コンテナ 1 起動 = 設定ブートストラップ 2 回
  entrypoint.sh
    ├─ jboss-cli.sh --file=(embed-server …)   ← 1 回目。current に standalone.v1.xml を残す
    └─ exec standalone.sh                     ← 2 回目。current が非空 → ★(B) rename が必ず走る
```

対応前は 1 起動 = 1 ブートストラップだったため、

* ECS (seed 方式) では `current` が存在しない → ★(A) で早期リターン → **rename は走らない**
* Compose (ボリューム無し) ではイメージ由来の `current` があれば rename が走るが、
  失敗しても WARN で済んでいた

という状態だった。「history の保存に失敗していたが起動自体はしていた」はこの状態を指す。

**`embed-server` を挟んだ瞬間、`current` は必ず非空になり、
`Files.move()` によるディレクトリ rename が毎起動の必須処理に昇格した。**

### 3-2. なぜ「ディレクトリ rename」だけが環境依存なのか

`Files.move(dir, dir2, REPLACE_EXISTING)` は JDK 内部で以下のように動く
(`sun.nio.fs.UnixCopyFile#move`)。

```
rename(2) を試す
  ├─ 成功                      → 完了
  ├─ errno == EXDEV            → mkdir(to) + rmdir(from) のフォールバックへ
  │                              from は非空ディレクトリなので rmdir が ENOTEMPTY
  │                              → java.nio.file.DirectoryNotEmptyException
  └─ それ以外の errno          → そのまま IOException として送出
                                 EACCES → AccessDeniedException
                                 EROFS  → FileSystemException: Read-only file system
                                 EBUSY  → FileSystemException: Device or resource busy
```

`rename(2)` が成立する条件は **「親ディレクトリに書き込み+実行権限がある」かつ
「from と to が同一ファイルシステム上にある」**。
JBoss EAP のブート処理の中で、この 2 条件に依存する操作は
**`createHistoryDirectory()` の ★(B) ただ 1 つ**である。
だから「configuration の実体が何か」で結果が割れるのはここだけになる。

そして `configuration` の実体は、2 つの対応を入れたことで環境ごとに完全に別物になっている。

| | `standalone/configuration` の実体 | `standalone_xml_history` の所有者 | root FS |
|---|---|---|---|
| **Compose (既定)** | イメージの **overlayfs** (ボリューム未指定) または自動コピー付き named volume | イメージ由来なら **下位レイヤ** | 書き込み可 |
| **ECS (seed 方式)** | **空のタスクローカルボリューム** (bind mount)。中身は `cp -R` で復元 | 起動時に**誰が作ったか**で決まる | `readonlyRootFilesystem=true` |

### 3-3. なぜ ECS だけ「異常終了」するのか — WARN と FATAL の分岐

★(C) の WARN が出た後、ブートは止まらずに ★(E) の `copyFile` へ進む。
**ここで分岐する。**

```
        ★(B) rename 失敗
              │
   ┌──────────┴───────────────────────────────┐
   │                                          │
 errno = EXDEV                          errno = EACCES / EROFS
 (overlayfs のレイヤ跨ぎ)                (親ディレクトリに書けない)
   │                                          │
 親ディレクトリ自体は書ける                    親ディレクトリに書けない
   │                                          │
 ★(E) copyFile は成功                    ★(E) copyFile も同じ理由で失敗
   │                                          │
 WFLYCTL0056 + 0414 だけ出て起動           WFLYCTL0082 → ブート異常終了
   │                                          │
 ＝ Compose の挙動                         ＝ ECS の挙動
```

**同じ WFLYCTL0414 が出ていても、原因の errno が違う。**
「Compose でも同じように history の保存に失敗している」という観察は正しいが、
**失敗の理由が同じとは限らない**というのが今回の環境差の正体である。

#### ECS 側で `EACCES` / `EROFS` になる典型パターン

| # | パターン | 発生条件 |
|---|---|---|
| E1 | `standalone_xml_history` が **root 所有 0755** で作られ、サーバは非 root (uid 185) で動く | エントリポイント (= `embed-server`) を root で実行し、`standalone.sh` を別ユーザーへ落として起動している。あるいは `umask 022` で root が作成 |
| E2 | ECS のタスクローカルボリュームが **root:root 0755** でマウントされ、`configuration` 直下に作るディレクトリが実行ユーザーから書けない | 実行ユーザーの gid がボリュームの gid と一致しない |
| E3 | `configuration` にボリュームを当てておらず `readonlyRootFilesystem=true` → **EROFS** | タスク定義の `mountPoints` 漏れ |
| E4 | `configuration` を **EFS** にしており、アクセスポイントの uid/gid と実行ユーザーが不一致 | `configuration` は本来タスクローカルにすべき |

Compose ではこれらがすべて起きない (root で動き、root FS も書ける) ため、
**Compose はこの不具合に対してテストとして機能していない**。

---

## 4. 10 秒で確定させる手順

### 4-1. ログから確定する (これが決定打)

CloudWatch (awslogs) で **WFLYCTL0414 の "1 行上" を見る**。必ず WFLYCTL0056 が出ている。

```bash
aws logs filter-log-events \
  --log-group-name /ecs/<service> \
  --filter-pattern '?WFLYCTL0056 ?WFLYCTL0414 ?WFLYCTL0082 ?WFLYCTL0051'
```

出てくる `WFLYCTL0056: Could not rename ... ` の **原因例外**で確定する。

| 原因例外 | errno | 判定 |
|---|---|---|
| `java.nio.file.DirectoryNotEmptyException` | EXDEV → rmdir ENOTEMPTY | **overlayfs のレイヤ跨ぎ**。ボリューム未マウント or イメージ由来の `current` |
| `java.nio.file.AccessDeniedException` | EACCES / EPERM | **所有者・権限の不一致** (E1 / E2 / E4) |
| `FileSystemException: ... Read-only file system` | EROFS | **`configuration` にボリュームを当てていない** (E3) |
| `FileSystemException: ... Device or resource busy` | EBUSY | `current` 自体がマウントポイントになっている |

### 4-2. コンテナの中から確定する

```bash
aws ecs execute-command --cluster <c> --task <t> --container <name> --interactive --command /bin/sh
```

```sh
id                                                     # 実行 uid/gid
mount | grep -E 'standalone|/mnt'                      # configuration に何がマウントされ ro か
ls -ld /opt/jboss-eap/standalone/configuration
ls -ld /opt/jboss-eap/standalone/configuration/standalone_xml_history        # ★ 所有者とモード
ls -la /opt/jboss-eap/standalone/configuration/standalone_xml_history/current

# 実書き込みテスト (EROFS と EACCES を取りこぼさない)
for p in /opt/jboss-eap/standalone/configuration \
         /opt/jboss-eap/standalone/configuration/standalone_xml_history; do
    if touch "$p/.w" 2>/dev/null; then rm -f "$p/.w"; echo "OK   $p"; else echo "NG   $p"; fi
done

# rename が通るかを直接見る (JBoss と同じ操作)
cd /opt/jboss-eap/standalone/configuration/standalone_xml_history \
  && mv current .probe && mv .probe current && echo "rename OK" || echo "rename NG"
```

---

## 5. Compose でも同じ失敗を再現させる (テストとして機能させる)

現状の Compose は ECS との差分を素通りしている。以下を入れると ECS の失敗がローカルで再現する。

```yaml
services:
  front:
    read_only: true                 # ← readonlyRootFilesystem=true 相当
    user: "185:0"                   # ← 非 root 実行を再現 (E1/E2 の条件)
    environment:
      EXTRASLB_HISTORY_MODE: "off"  # ← 本修正を無効化して従来動作を再現
    volumes:
      - type: volume
        source: front-jboss-conf
        target: /opt/jboss-eap/standalone/configuration
        volume: { nocopy: true }    # ← ★ イメージからの自動コピーを無効化 (ECS と同じ挙動)
      - type: volume
        source: front-jboss-tmp
        target: /opt/jboss-eap/standalone/tmp
        volume: { nocopy: true }
      - type: volume
        source: front-jboss-data
        target: /opt/jboss-eap/standalone/data
        volume: { nocopy: true }

volumes:
  front-jboss-conf:
  front-jboss-tmp:
  front-jboss-data:
```

`nocopy: true` + `read_only: true` + `user:` の 3 つが、ECS だけで落ちる原因をローカルへ引きずり出す。
CI のスモークテストにはこの構成を使う。

---

## 6. 修正方針

3 段構えで、**どの errno のケースでも落ちない**ようにする。

| 段 | 方針 | 効くケース |
|:--:|---|---|
| **①** | **起動あたりの設定ブートストラップを 1 回に戻す** — Elytron 設定を**ビルド時**に適用し、起動時の `embed-server` を不要にする。起動時は `standalone.xml` にマーカーがあれば CLI を自動スキップ | **引き金そのものを消す**。全ケース |
| **②** | **rename を発生させない** — `standalone.sh` に制御を渡す前に `standalone_xml_history/current` を空にする。WildFly は ★(A) の判定で rename をスキップする。退避は `rename` ではなく `cp` + `rm` で行うのでレイヤ跨ぎでも成功する | EXDEV / EACCES / EROFS / EBUSY すべて |
| **③** | **所有権を実行ユーザーに固定し、fail-fast する** — `standalone_xml_history` / `snapshot` / `current` をエントリポイント自身が作り (= 実行ユーザー所有になる)、実書き込みで検証して、駄目なら**理由を明示して即終了**する | E1 / E2 / E3 / E4。JBoss のスタックトレースではなく原因を名指しできる |

加えて、ECS 固有の無音死を 1 つ潰した:

| 段 | 方針 | 効くケース |
|:--:|---|---|
| **④** | `mktemp /tmp/…` をやめ、**書き込み可能なディレクトリを順に探す** | `readonlyRootFilesystem=true` で `/tmp` が EROFS になり、`set -e` でエントリポイントが即死していた (JBoss のログが 1 行も出ないパターン) |

### 6-1. なぜ「current を空にする」で直るのか

★(A) の条件 `currentHistoryFiles.length > 0` を満たさなくすれば、
`forcedMove()` (= `Files.move()`) は **呼ばれない**。
`current` を空にする操作はエントリポイント側で行うため、
`cp -R` (レイヤ跨ぎ可) + `rm -rf` (中身のみ) という **rename を使わない手段**で実現できる。

退避先のディレクトリ名は WildFly と同じ `yyyyMMdd-HHmmssSSS` 形式にしてあるので、
WildFly 側の 30 日クリーンアップ (`TIMESTAMP_PATTERN = \d{8}-\d{9}`) の対象になり、
退避物が無限に溜まることもない。

### 6-2. 失われる情報はあるか

`rotate` (既定) では失われない。

* `current/standalone.v1.xml` (= CLI 適用**前**の `standalone.xml`) は
  `standalone_xml_history/<timestamp>/standalone.v1.xml` へ退避される
* 同じ内容は `configuration-seed/standalone.xml` にも残っている (seed 方式併用時)
* `standalone.initial.xml` / `.boot.xml` / `.last.xml` は削除しない

---

## 7. 変更後の起動シーケンス

```
[ENTRYPOINT] efs-entrypoint.sh   (configuration-seed 方式・別リポジトリ)
   1. configuration-seed → configuration の書き戻し
   2. EFS ログディレクトリ作成 / mid/current の張り替え
   3. tmp / data / log の実書き込み検証
   └─ exec "$@"
        │
[CMD] entrypoint.sh              (本リポジトリ・今回修正)
   1. truststore / configuration / standalone.xml の存在と実書き込み検証
   2. standalone_xml_history, snapshot, current を **自分で** mkdir
      → 所有者が実行ユーザーに固定される (E1/E2 の予防)
      → ここで書けなければ WFLYCTL0082 になる前に理由付きで exit 1
   3. EXTRASLB_TLS_CONFIG_MODE=auto
        standalone.xml に extraslb-client-ssl-context があれば CLI をスキップ
          → ビルド時適用済みイメージでは **embed-server は 1 度も動かない**
        無ければ jboss-cli.sh --file=(embed-server …) を実行
          → 一時ファイルは書き込み可能なディレクトリを自動選択 (/tmp が EROFS でも動く)
          → 失敗したら診断を出して exit 1 (set -e による無音死をしない)
   4. EXTRASLB_HISTORY_MODE=rotate
        current の中身を standalone_xml_history/<yyyyMMdd-HHmmssSSS>/ へ cp で退避し、
        current を空にする  ★ これで本ブートの rename が発生しなくなる
   5. exec standalone.sh -b … -c … -Djavax.net.ssl.*
        │
[JBoss EAP 本ブート]
   createHistoryDirectory():
     current は空 → ★(A) で早期リターン → rename しない → WFLYCTL0056/0414 は出ない
   successfulBoot():
     standalone_xml_history/ は実行ユーザー所有 → ★(E) copyFile 成功 → WFLYCTL0082 も出ない
```

---

## 8. どこを修正実装したか

### 8-1. `base/scripts/entrypoint.sh` ★ 本丸

| 章 | 追加/変更内容 | 対応する方針 |
|---|---|---|
| 冒頭コメント | なぜ履歴の正規化が必要かを WFLYCTL の ID 付きで明記 | — |
| 変数定義 | `JBOSS_CONF_DIR` を参照 (seed 方式の `efs-entrypoint.sh` と同じ変数名)。`HISTORY_DIR` / `CURRENT_HISTORY_DIR` を定義 | 併用対応 |
| `0. 診断ヘルパー` | `say` / `warn` / `die` / `dump_diag` / `is_writable` を追加。異常時は `id` / `ls -la` / `mount` を stderr へ出す | ③ |
| `1. 事前検証` | truststore・`configuration`・`standalone.xml` の存在と **実書き込み**を検証。`standalone.xml` が無い場合は「seed の書き戻しより後に動かすこと」と明示 | ③ |
| `2. 履歴ディレクトリを先に作る` | `standalone_xml_history` / `snapshot` / `current` を **エントリポイントが** `mkdir` + `chmod g+rwX`。書けなければ WFLYCTL0082 になる前に `die` | ③ |
| `3. JBoss CLI` | `EXTRASLB_TLS_CONFIG_MODE=auto` で**設定済みならスキップ**。一時ファイルは書き込み可能ディレクトリを自動選択。CLI 失敗時は診断付きで `die` | ①④ |
| `4. 履歴の正規化` | **`normalize_history()` を新設**。`current` が非空なら `<timestamp>` へ `cp -R` で退避し、中身を `rm` して空にする | ② |
| `5. EAP 起動` | 変更なし (`exec standalone.sh …`) | — |

**最重要の関数** (`base/scripts/entrypoint.sh` の `4.` ブロック):

```bash
normalize_history() {
    [[ -d "${CURRENT_HISTORY_DIR}" ]] || return 0
    if [[ -z "$(ls -A "${CURRENT_HISTORY_DIR}" 2>/dev/null)" ]]; then
        say "standalone_xml_history/current は空です (履歴ローテーションは発生しません)"
        return 0
    fi
    if [[ "${EXTRASLB_HISTORY_MODE}" == "rotate" ]]; then
        ts="$(history_timestamp)"                       # yyyyMMdd-HHmmssSSS
        backup="${HISTORY_DIR}/${ts}"
        mkdir -p "${backup}" && cp -R "${CURRENT_HISTORY_DIR}/." "${backup}/"   # rename を使わない
    fi
    find "${CURRENT_HISTORY_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +     # 中身だけ削除
}
```

### 8-2. `base/Dockerfile`

トラストストア生成 RUN の直後、`USER 185` の直前に **RUN を 1 つ追加**した。

| 追加内容 | 目的 |
|---|---|
| `ARG APPLY_TLS_CONFIG_AT_BUILD=true` — ビルド時に `embed-server` で Elytron 設定を適用 | ① 起動時の `embed-server` を不要にする。`EXTRASLB_TLS_CONFIG_MODE=auto` が自動でスキップするので、**起動あたりのブートストラップが 1 回に戻る** |
| `rm -rf "${CONF_DIR}/standalone_xml_history"` | **イメージ内に `current` を残さない**。残っていると overlayfs の下位レイヤになり、ボリューム未指定の Compose 環境で毎回 EXDEV → WFLYCTL0056/0414 が出る |
| `chown -R ${RUN_UID}:${RUN_GID}` + `chmod -R g+rwX "${CONF_DIR}"` | ビルド時に root で書き換えた設定ファイルの所有権を実行ユーザーへ戻す。**これを忘れると起動時に `standalone.xml` を書けず EACCES になる** |

> `APPLY_TLS_CONFIG_AT_BUILD=false` にすると適用をスキップする
> (JBoss EAP 本体を含まないベースイメージを使う場合など)。
> その場合も起動時に `entrypoint.sh` が適用し、履歴の正規化も行うため安全に動作する。

**配置順の注意 (2 点)**

1. この RUN は **JBoss EAP 導入 RUN より後ろ**に置く (`standalone.xml` が無いとスキップされる)。
2. この RUN は **`standalone/log` を EFS へのシンボリックリンクに置き換える前**
   (= base イメージ側) で実行する。`embed-server` はブート時に `jboss.server.log.dir` へ
   書き込むため、リンク先の EFS が存在しないビルド時にリンク化されていると失敗する。
   `configuration-seed` 方式では log のリンク作成は front / back の Dockerfile 側なので、
   base に置いてある限り問題は起きない。

**`configuration-seed` 方式と併用する場合の順序**

`configuration` → `configuration-seed` の退避 RUN は、
**この RUN よりさらに後ろ**に置く。そうしないと Elytron 設定の入っていない
`standalone.xml` が seed に焼き込まれ、起動時の `cp -R` で設定が消える。

```
JBoss EAP 導入
  └→ (本リポジトリ) Elytron 設定のビルド時適用 + standalone_xml_history 削除
       └→ (seed 方式)  configuration → configuration-seed の退避
```

### 8-3. 併用時のワイヤリング (front / back の Dockerfile)

`configuration-seed` 方式と併用する場合、**seed の書き戻しより後に本 entrypoint が動く**必要がある。

```dockerfile
ENTRYPOINT ["/usr/local/bin/efs-entrypoint.sh"]   # 1. configuration-seed の書き戻し
CMD        ["/usr/local/bin/entrypoint.sh"]       # 2. Elytron 設定 + 履歴正規化 + standalone.sh
```

逆順 (`entrypoint.sh` を ENTRYPOINT にする) にすると、
**CLI が書いた `standalone.xml` を seed の `cp -R` が上書きして Elytron 設定が消える**。
本修正では `standalone.xml` が見つからない場合にこの旨を明示して `exit 1` する。

### 8-4. 追加実装 (`readonlyRootFilesystem=false` / ボリューム無し構成への対応)

13 章以降の構成が判明した後に `base/scripts/entrypoint.sh` へ追加した分。
設計意図は [14-2](#14-2-追加した実装--rename-検査と履歴ツリーの作り直し) を参照。

| 追加箇所 | 内容 | 目的 |
|---|---|---|
| `2.` ブロック末尾 | **`configuration` がマウントかどうかを起動ログへ出力** (`/proc/self/mounts` を参照) | 「ボリュームを当てたつもりが当たっていない」「overlayfs 上なので rename が原理的に通らない」の即時切り分け |
| `4-2.` **`history_rename_probe()`** (新規関数) | `mv` 前後の **inode 一致**で `rename(2)` の成否を実測。`mv` は EXDEV でコピー+削除にフォールバックして成功するため、`mv` の成否では判定できない | 環境がどちらの分岐かを**毎起動ログに残す**。診断そのものになる |
| `4-3.` **`recreate_history()`** (新規関数) | 履歴ツリーを退避 → `rm -rf` → `mkdir` → 書き戻し。overlayfs では whiteout + opaque upper になり **以後 `rename` が通る** | イメージを作り直せない場合の起動時救済。`:reload` 時の JBoss 自身のローテーションまで成功させる |
| モード分岐 | `EXTRASLB_HISTORY_MODE` に **`recreate`** を追加。`EXTRASLB_HISTORY_AUTO_RECREATE` (既定 `true`) で probe NG 時のみ自動作り直し | 必要な環境でだけ作り直し、ボリューム構成では無駄な処理をしない |
| 変数定義部 | `EXTRASLB_HISTORY_MODE` の**値バリデーション** (不正値は即 `exit 1`) | タイプミスが「何も起きない」で埋もれるのを防ぐ |

---

## 9. 環境変数

| 変数 | 既定 | 意味 |
|---|---|---|
| `EXTRASLB_TLS_CONFIG_MODE` | `auto` | `auto` = `standalone.xml` に `extraslb-client-ssl-context` があれば CLI をスキップ / `always` = 毎起動実行 / `skip` = 実行しない |
| `EXTRASLB_HISTORY_MODE` | `rotate` | `rotate` = `current` を `<timestamp>` へ退避して空にする / `recreate` = `rotate` に加えて `standalone_xml_history` 自体を必ず作り直す (14-2) / `purge` = 退避せず空にする / `off` = 何もしない (**従来動作・障害再現用**)。不正値はその場で `exit 1` |
| `EXTRASLB_HISTORY_AUTO_RECREATE` | `true` | `rename(2)` が通らないと**実測できた場合にだけ**履歴ツリーを作り直す。overlayfs の merged ディレクトリ対策 (13-2 / 14-2)。`false` で検査自体を行わない |
| `EXTRASLB_STRICT_PREFLIGHT` | `true` | `false` にすると書き込み検証の失敗を警告に留めて起動を続行する |
| `EXTRASLB_TMP_DIR` | (自動選択) | CLI 一時ファイルの置き場所。自動選択の順序は `EXTRASLB_TMP_DIR` → `TMPDIR` → `$JBOSS_HOME/standalone/tmp` → `configuration` → `/tmp` |
| `EXTRASLB_TLS_MARKER` | `extraslb-client-ssl-context` | `auto` 判定に使う `standalone.xml` 内のマーカー文字列 |
| `EXTRASLB_CLI_SCRIPT` | `/opt/app/cli/configure-outbound-tls.cli` | 適用する CLI スクリプト |
| `JBOSS_CONF_DIR` | `${JBOSS_HOME}/standalone/configuration` | configuration ディレクトリ (seed 方式と同じ変数名) |

既存の `EXTRASLB_TRUSTSTORE_*` / `SERVER_CONFIG` / `JBOSS_BIND_ADDRESS` は変更なし。

---

## 10. 検証手順

### 10-1. 正常時に出るログ

```
==> [entrypoint] JBOSS_HOME=/opt/jboss-eap, SERVER_CONFIG=standalone.xml
==> [entrypoint] configuration=/opt/jboss-eap/standalone/configuration
==> [entrypoint] truststore=/opt/app/security/extraslb-truststore.p12
==> [entrypoint] standalone.xml に extraslb-client-ssl-context が既に存在するため JBoss CLI をスキップします
==> [entrypoint] (2 回目の設定ブートストラップが発生しないため履歴ローテーションも起きません)
==> [entrypoint] standalone_xml_history/current は空です (履歴ローテーションは発生しません)
==> [entrypoint] preflight OK. starting JBoss EAP
```

ビルド時適用をしていない場合はこうなる。

```
==> [entrypoint] Applying Elytron outbound TLS configuration via JBoss CLI (tmp=/opt/jboss-eap/standalone/tmp)
… (CLI の success 出力) …
==> [entrypoint] JBoss CLI configuration completed
==> [entrypoint] standalone_xml_history/current を 20260904-101532417 へ退避しました
==> [entrypoint] standalone_xml_history/current を空にしました (mode=rotate)
==> [entrypoint] preflight OK. starting JBoss EAP
```

**この行が出ていなければ、出ていない行の直前が失敗箇所**である。
異常時は `FATAL:` に続けて `id` / `ls -la configuration` / `ls -la standalone_xml_history` / `mount` の
診断ダンプが stderr に出る。

### 10-2. 起動後の確認

```bash
# WFLYCTL0056 / 0414 / 0082 が出ていないこと
docker logs <container> | grep -E 'WFLYCTL0056|WFLYCTL0414|WFLYCTL0082|WFLYCTL0051' || echo "OK: 履歴エラー無し"

# 履歴が正しく作られていること
docker exec <container> ls -la /opt/jboss-eap/standalone/configuration/standalone_xml_history

# Elytron 設定が効いていること
docker exec <container> $JBOSS_HOME/bin/jboss-cli.sh -c \
  '/subsystem=elytron:read-attribute(name=default-ssl-context)'
docker exec <container> $JBOSS_HOME/bin/jboss-cli.sh -c \
  '/subsystem=elytron/client-ssl-context=extraslb-client-ssl-context:read-resource'
```

### 10-3. 回帰テスト (障害を意図的に再現する)

```bash
# EXTRASLB_HISTORY_MODE=off で従来動作に戻すと WFLYCTL0056/0414 が復活する
docker run --rm -e EXTRASLB_HISTORY_MODE=off -e EXTRASLB_TLS_CONFIG_MODE=always myapp-front:1.0
```

CI では 5 章の Compose 構成 (`nocopy: true` + `read_only: true` + `user:`) で
`EXTRASLB_HISTORY_MODE` の既定値のまま起動できることを確認する。

---

## 11. チェックリスト

- [ ] ベースイメージのビルドログに `[base] applied Elytron outbound TLS configuration at build time` が出ている
- [ ] イメージ内に `standalone/configuration/standalone_xml_history` が **無い**
      (`docker run --rm --entrypoint sh <image> -c 'ls -la "$JBOSS_HOME/standalone/configuration"'`)
- [ ] `standalone/configuration` 配下の所有者が実行ユーザー (uid 185 等) になっている
- [ ] front / back の Dockerfile が `ENTRYPOINT=efs-entrypoint.sh` / `CMD=entrypoint.sh` の順になっている
- [ ] タスク定義に `configuration` / `tmp` / `data` の書き込み可能ボリュームがある
- [ ] `configuration` 用ボリュームは **EFS ではなくタスクローカル** である
- [ ] `configuration` 用ボリューム名が front / back で重複していない
- [ ] 起動ログに `==> [entrypoint] preflight OK.` が出ている
- [ ] 起動ログに WFLYCTL0056 / WFLYCTL0414 / WFLYCTL0082 が出ていない
- [ ] Compose 側に `nocopy: true` + `read_only: true` + `user:` を入れた再現テスト済み

---

## 12. 補足 — なぜこの不具合は Compose で見つからなかったのか

`configuration-seed` 方式のドキュメント (`ECS_EFS_Dockerfile_Symboliclink_lite/docs/TROUBLESHOOTING.md`)
が指摘しているとおり、Compose と ECS には少なくとも 3 つの差分がある。

| # | 差分 | 効き方 |
|---|---|---|
| 1 | `readonlyRootFilesystem=true` | Compose は既定でルート FS が書ける。`/tmp` の `mktemp` も通る |
| 2 | 空ボリュームへのイメージ内容の自動コピー | Docker の named volume は初回マウント時にイメージ側の中身を自動コピーする (`nocopy: true` を付けない限り)。**ECS / Fargate は一切コピーしない** |
| 3 | 実行ユーザーと uid/gid の強制 | Compose は `user:` 未指定なら root で素通り。ECS + EFS AP では uid/gid が強制される |

今回の不具合はこの 3 つ**すべて**に触る。
`standalone_xml_history` のローテーションは
「どのファイルシステムか」「誰の所有か」「書けるか」の 3 点に同時に依存する唯一の処理であり、
上記 3 差分の交点にちょうど乗ってしまっている。

**Compose を ECS に寄せる (5 章) までは、この種の不具合はローカルで検出できない。**

---

# 【構成別 追補】現行構成 — `readonlyRootFilesystem=false` / ボリューム無し / seed 有効

ここまでの 0〜12 章は
「`readonlyRootFilesystem=true` + `configuration` にタスクローカルボリューム」
を前提にしていた。実際に問題が出ているのは**それとは違う次の構成**である。

| 項目 | 現行の状態 |
|---|---|
| `readonlyRootFilesystem` | **`false`** (対応を止めた) |
| `standalone/configuration` などへのボリューム / bind mount | **無し** |
| tmpfs | **無し** |
| `configuration-seed` の書き戻し | **有効のまま** |

本章はこの構成に対する **(A) 何が起きているのかの再分析**、
**(B) これまでの対処法が有効かどうか**、
**(C) この構成向けに追加した実装パターン**をまとめる。

---

## 13. この構成で実際に起きていること

### 13-1. `configuration` の実体は「イメージの overlayfs」

ボリュームを当てていないので、`/opt/jboss-eap/standalone/configuration` は
**コンテナイメージの overlayfs (overlay2)** そのものである。

```
/opt/jboss-eap/standalone/configuration
   ├─ lower  = イメージのレイヤ (読み取り専用)
   └─ upper  = コンテナの書き込みレイヤ (タスクごとに新規・破棄)
```

`configuration-seed` の書き戻し (`cp -R seed/. configuration/`) は
**upper に個々のファイルをコピーアップするだけ**で、
ディレクトリの lower/upper 構造は変えない。

### 13-2. overlayfs は「lower を持つディレクトリ」の rename を原理的に拒否する

これがこの構成での**決定的な事実**である。

* Linux の overlayfs は、`rename(2)` の対象が
  **下位レイヤ由来のディレクトリ (pure lower / merged ディレクトリ)** の場合、
  **無条件に `-EXDEV` を返す**。
* 回避には `redirect_dir=on` (カーネルの `CONFIG_OVERLAY_FS_REDIRECT_DIR` /
  `modprobe overlay redirect_dir=on`) が必要だが、**Docker / containerd の既定は off**。
* **一度でも upper へコピーアップされても解決しない。** コピーアップは
  「upper にも実体を作る」だけで lower は消えないため、そのディレクトリは
  merged のままであり、`rename` は永久に `EXDEV` を返し続ける。

つまり、**`configuration/standalone_xml_history/current` がイメージに焼き込まれていると、
所有者・権限が完全に正しくても、そのコンテナが生きている限り rename は絶対に成功しない。**

```
Files.move(current, <timestamp>, REPLACE_EXISTING)
  -> rename(2) = EXDEV
  -> JDK が mkdir(target) + rmdir(source) にフォールバック
  -> source は非空 -> rmdir = ENOTEMPTY
  -> java.nio.file.DirectoryNotEmptyException
  -> WFLYCTL0056 (ERROR) + WFLYCTL0414 (WARN)
```

### 13-3. なぜイメージに `standalone_xml_history/current` が入るのか

**イメージビルド中に一度でもサーバ (または `jboss-cli.sh` の `embed-server`) を起動していると入る。**
典型例:

* ビルド時にデータソース / ロギング / セキュリティドメインを CLI で設定している
* Galleon / JBoss EAP Maven プラグインでプロビジョニングしている
* 動作確認のために `standalone.sh` を一度起動している

`configuration-seed` 方式の Dockerfile は
`rm -rf "${JBOSS_CONF_SEED_DIR}/standalone_xml_history"` で
**seed 側からは除いている**が、**`configuration` 側 (= イメージ本体) には残したまま**である。
そのため lower レイヤの `current` は生き続ける。

### 13-4. 「対応前は失敗していたが起動していた」の説明

| | `current` の状態 | rename | 結果 |
|---|---|---|---|
| **対応前** (CLI 無し) | イメージ由来で非空 | EXDEV で失敗 | WFLYCTL0056/0414 が出るが、`standalone_xml_history` への**ファイル書き込みは overlayfs のコピーアップで成功**するため `successfulBoot()` は完走 → **起動する** |
| **対応後** (CLI あり) | 同上 + embed-server が `standalone.vN.xml` を追加 | 同じく EXDEV で失敗 | 同じ経路をたどるが、**ブートが 2 回になり所要時間・書き込み量・ピークメモリが増える** |

**重要**: この構成では、WFLYCTL0056/0414 は **ECS でも Compose でも同じ理由 (EXDEV) で出る**。
つまり **0〜12 章で説明した「errno が違うから結果が割れる」という分岐は、この構成には当てはまらない。**
ボリュームも readonly も無いため、両者のファイルシステム上のふるまいは同一になる。

→ **この構成で「ECS だけ異常終了する」場合、原因はファイルシステム以外にある。** 15 章で切り分ける。

---

## 14. これまでの対処法は有効か — 有効性マトリクス

| # | 対処 | 現行構成での有効性 | 補足 |
|:--:|---|:--:|---|
| ① | **Elytron 設定のビルド時適用** (`base/Dockerfile`) → 起動時 `embed-server` を不要にする | **◎ 有効・最優先** | ブートが 1 回に戻り、**起動時間・メモリピーク・書き込み量が対応前の水準に戻る**。15 章の候補 (b)(c) を同時に潰す |
| ② | **`current` を空にして rename を発生させない** (`EXTRASLB_HISTORY_MODE=rotate`) | **◎ 有効** | `cp` + `rm` で行うため overlayfs でも成立。WFLYCTL0056/0414 がブート時に出なくなる |
| ★ | **イメージから `standalone_xml_history` を削除** (`base/Dockerfile`) | **◎ この構成では最重要** | lower レイヤの `current` が消えるので **EXDEV が原理的に起きなくなる**。13-2 の制約から抜け出せる唯一の根本策 |
| ★ | **rename 検査 + 履歴ツリーの作り直し** (`EXTRASLB_HISTORY_AUTO_RECREATE`) | **◎ この構成向けに追加** | ベースイメージを作り直せない場合の起動時救済。`:reload` 時のローテーションまで通るようになる (14-2) |
| ③ | **履歴ディレクトリを実行ユーザーで先に `mkdir` + 実書き込み検証** | **○ 有効 (効き所が変わる)** | EROFS / 未マウントは起きないので、主眼は **タスク定義の `user` 指定による uid 不一致の早期検出** (15 章 (a)) |
| ④ | **`/tmp` の EROFS 回避 (一時ファイル置き場の自動選択)** | **△ 現時点では不要 / 害は無い** | `readonlyRootFilesystem=false` なので `/tmp` は書ける。**将来 readonly 化したときにそのまま効く**ので残しておく |
| — | タスク定義へのボリューム追加 | **不要** | 現行方針では行わない。将来 readonly 化するときに 5-3 章の内容へ戻る |

**結論: 有効。ただし「効いている理由」が変わる。**
`readonlyRootFilesystem=true` 前提では ② と ③ が主役だったが、
この構成では **★ (イメージからの履歴削除) と ① (ビルド時適用)** が主役になる。

### 14-1. `configuration-seed` の扱い — この構成では「無害ではない」

**ボリュームが無い以上、seed の書き戻しは何の役にも立たない。**
イメージの `configuration` はそのまま見えているので、
`cp -R seed/. configuration/` は同じ内容を上書きコピーしているだけである。

それだけなら無害だが、**1 つだけ実害のあるケースがある。**

> **seed を「ビルド時の Elytron 設定適用より前」に取得していると、
> 起動のたびに `standalone.xml` が設定前の内容へ巻き戻される。**
> すると `EXTRASLB_TLS_CONFIG_MODE=auto` はマーカーを見つけられず CLI を再実行し、
> **せっかく消した二重ブートストラップが毎起動復活する。**

対処は次のどちらか。

* **(推奨) `CONFIG_SEED_MODE=skip`** — ボリュームを当てていない間は seed の書き戻しを止める。
  将来 `readonlyRootFilesystem=true` + ボリュームへ戻すときに `overwrite` へ戻せばよい。
* **seed の取得を「ビルド時適用の後ろ」に置く** — Dockerfile の並び順を次にする。

```
JBoss EAP 導入
  └→ (本リポジトリ) Elytron 設定のビルド時適用 + standalone_xml_history 削除
       └→ (seed 方式) configuration → configuration-seed の退避
```

### 14-2. 追加した実装 — rename 検査と履歴ツリーの作り直し

ベースイメージを作り直せない (= イメージ内の `standalone_xml_history` を消せない) 場合でも、
**起動時に履歴ツリーを作り直せば merged 状態から抜け出せる。**

overlayfs では、ディレクトリを `rm -rf` すると upper に **whiteout** が作られ、
同名で `mkdir` し直すと **opaque な upper 専用ディレクトリ**になる。
opaque ディレクトリは下位レイヤを持たないため、**以後 `rename(2)` が通る**。

`entrypoint.sh` はこれを自動で行う。判定は「実測」で行う。

```bash
# mv は EXDEV のとき「コピー + 削除」へフォールバックして成功してしまうため、
# mv の成否では判定できない。mv の前後で inode が保たれたかで rename(2) の成否を見る。
before="$(stat -c %i "${CURRENT_HISTORY_DIR}")"
mv "${CURRENT_HISTORY_DIR}" "${probe}"
after="$(stat -c %i "${probe}")"
[[ "${before}" == "${after}" ]]      # 同じ = rename(2) 成功 / 違う = フォールバック
```

* 検査は `current` を空にした**後**に行うので、フォールバックしても副作用は無い。
* NG のときだけ `standalone_xml_history` を退避 → 削除 → 再作成 → 書き戻す。
  `<timestamp>` ディレクトリや `standalone.initial.xml` などの履歴は**保全される**。
* 判定結果は毎起動ログに出るので、**そのまま診断情報になる**。

```
==> [entrypoint] configuration はマウントされていません (イメージの overlayfs 上で動作)
==> [entrypoint] 履歴ディレクトリの rename 検査: NG
==> [entrypoint]   -> .../standalone_xml_history は overlayfs の下位レイヤを持つ merged ディレクトリです。
==> [entrypoint]   -> このままでは :reload 等のたびに WFLYCTL0056/0414 が出続けるため作り直します。
==> [entrypoint] standalone_xml_history を上位レイヤ専用ディレクトリとして作り直しました
```

> **なぜ `current` を空にするだけでは足りないのか**
> WildFly が履歴をローテーションするのは**ブート時 (`createHistoryDirectory()`)** だけではない。
> `:reload` は再ブートなので同じ処理が走る。`current` を空にする対策は
> 「entrypoint が動く起動時」しか効かないが、履歴ツリーを upper 専用にしておけば
> **`:reload` 時の JBoss 自身のローテーションも成功する**ようになる。

---

## 15. この構成で「ECS だけ異常終了する」ときの切り分け

13-4 のとおり、この構成では**ファイルシステムのふるまいは ECS と Compose で同じ**になる。
したがって差が出るなら原因は別にある。**可能性の高い順に**次を潰す。

### 手順 0 — まず「本当に JBoss が落としたのか」を確定する

```bash
aws ecs describe-tasks --cluster <cluster> --tasks <task-arn> \
  --query 'tasks[0].{stopped:stoppedReason,containers:containers[].{name:name,exit:exitCode,reason:reason}}'
aws ecs describe-services --cluster <cluster> --services <svc> --query 'services[0].events[:10]'
```

| 見えるもの | 意味 |
|---|---|
| `exitCode: 1` + `Essential container in task exited` | JBoss / entrypoint が自分で落ちた → (a)(d) へ |
| `exitCode: 137` / `OutOfMemoryError: Container killed` | **メモリ不足** → (c) |
| `stoppedReason: Task failed ELB health checks` / `container healthcheck` | **ヘルスチェック** → (b) |
| `exitCode: 143` | SIGTERM = ECS 側からの停止 → (b) |

### (a) タスク定義の `user` 指定と、イメージの `USER` の不一致 ★最有力

```bash
aws ecs describe-task-definition --task-definition <td> \
  --query 'taskDefinition.containerDefinitions[].{name:name,user:user}'
```

`user` を指定していると、**イメージの `USER` とは違う uid** でプロセスが動く。
イメージ内の `configuration` 配下は別 uid 所有なので、
`standalone_xml_history` への書き込みが `EACCES` となり
**WFLYCTL0082 でブートが異常終了する**。
Compose 側は `user:` 未指定＝イメージどおりの uid なので再現しない。

コンテナ内で確定させる。

```sh
id
ls -ln /opt/jboss-eap/standalone/configuration
ls -ln /opt/jboss-eap/standalone/configuration/standalone_xml_history
touch /opt/jboss-eap/standalone/configuration/standalone_xml_history/.w && echo OK || echo NG
```

対処: タスク定義の `user` を外す (イメージの `USER` に任せる) か、
Dockerfile で `chown -R <uid>:<gid>` + `chmod -R g+rwX` を `configuration` に当てる
(本リポジトリの `base/Dockerfile` は `RUN_UID` / `RUN_GID` で対応済み)。
`entrypoint.sh` は JBoss へ渡す前にこれを実書き込みで検証して
**理由付きで `exit 1`** するので、修正後は WFLYCTL0082 ではなく
`FATAL: ... に書き込めません` が出るようになる。

### (b) 起動時間の倍増でヘルスチェックに間に合っていない ★次点

`embed-server` は**本物のコントローラを 1 回ブートする**ため、
起動時間はおおむね **2 倍**になる。

* コンテナ `healthCheck.startPeriod`
* サービスの `healthCheckGracePeriodSeconds` (ALB / NLB ターゲットグループ)

これらを超えると ECS がタスクを停止する。Compose にはヘルスチェックが無い (か緩い) ので起動する。
**「ログの最後が JBoss の起動途中で、その直前に WFLYCTL0414 がある」**という見え方になるため、
WFLYCTL0414 が原因に見えてしまう典型パターンでもある。

対処: **① のビルド時適用でブートを 1 回に戻す**のが本筋。
暫定的には `startPeriod` / `healthCheckGracePeriodSeconds` を延ばす。

### (c) メモリのハードリミット

CLI (embed-server) の JVM とサーバの JVM は逐次実行だが、
`-Xmx` はコンテナメモリから算出されるため**ピークが上がる**。
`exitCode: 137` なら確定。対処は ① か、タスクのメモリを増やす。

### (d) `${env.*}` 式がタスク定義で解決できていない

`standalone.xml` には `${env.EXTRASLB_TRUSTSTORE_PATH:...}` のような式が保存される。
既定値付きなので通常は問題ないが、**既定値の無い式を追加している場合**、
タスク定義に環境変数が無いと起動時解決に失敗してブートが落ちる。
Compose 側は `.env` などで設定済みだと差が出る。

```bash
docker run --rm --entrypoint sh <image> -c \
  'grep -o "env\.[A-Za-z0-9_]*" "$JBOSS_HOME/standalone/configuration/standalone.xml"' | sort -u
```

### (e) イメージ世代のズレ

ECR のタグとローカルビルドのイメージが同一かを `docker inspect --format '{{.Id}}'` /
`aws ecr describe-images` の digest で突き合わせる。

---

## 16. 現行構成での推奨設定 (そのまま貼れる形)

### 16-1. ビルド (最優先。これだけで大半が解決する)

`base/Dockerfile` は対応済み。**自前の merged Dockerfile で JBoss EAP を導入している場合は、
EAP 導入 RUN の後ろに次の 3 つを必ず入れる。**

```dockerfile
# 1) Elytron 設定をビルド時に適用 (起動時の embed-server を不要にする)
RUN { echo "embed-server --server-config=standalone.xml --std-out=echo"; \
      cat /opt/app/cli/configure-outbound-tls.cli; \
      echo "stop-embedded-server"; } > /tmp/tls.cli \
    && "${JBOSS_HOME}/bin/jboss-cli.sh" --file=/tmp/tls.cli \
    && rm -f /tmp/tls.cli

# 2) ★ イメージに履歴を残さない (overlayfs の EXDEV を原理的に消す)
RUN rm -rf "${JBOSS_HOME}/standalone/configuration/standalone_xml_history"

# 3) 実行ユーザーが書けるようにする (uid はイメージの USER に合わせる)
RUN chown -R 185:0 "${JBOSS_HOME}/standalone/configuration" \
    && chmod -R g+rwX "${JBOSS_HOME}/standalone/configuration"
```

> `standalone/log` を EFS へのシンボリックリンクに置き換える RUN より**前**に置くこと
> (embed-server は `jboss.server.log.dir` へ書き込むため)。
> `configuration-seed` の退避 RUN より**前**に置くこと (14-1)。

### 16-2. タスク定義 (環境変数)

```jsonc
{
  "containerDefinitions": [{
    "name": "intra-web-front",
    "readonlyRootFilesystem": false,          // 現行方針のまま
    // "user" は指定しない (イメージの USER に任せる)。指定するなら 15-(a) の対処を必ず行う
    "environment": [
      { "name": "CONFIG_SEED_MODE",         "value": "skip"   },  // ボリューム無しの間は書き戻し不要 (14-1)
      { "name": "EXTRASLB_TLS_CONFIG_MODE", "value": "auto"   },  // ビルド時適用済みなら CLI をスキップ
      { "name": "EXTRASLB_HISTORY_MODE",    "value": "rotate" }   // 既定。明示しておくと意図が伝わる
    ],
    "healthCheck": { "startPeriod": 180 }     // ① を入れるまでの暫定 (15-(b))
  }],
  "volumes": []                               // 現行方針: ボリュームは当てない
}
```

`CONFIG_SEED_MODE=skip` にできない事情がある場合は、
**seed をビルド時適用の後ろで取得している**ことを確認する (14-1)。

### 16-3. ベースイメージを作り直せない場合の暫定運用

`base/Dockerfile` を変えられない (= イメージに `standalone_xml_history` が残る) 場合は、
起動時の自動作り直しに任せる。**追加設定は不要** (既定で有効)。

```jsonc
{ "name": "EXTRASLB_HISTORY_AUTO_RECREATE", "value": "true" }   // 既定値。明示する場合
```

毎起動必ず作り直したいなら次を指定する。

```jsonc
{ "name": "EXTRASLB_HISTORY_MODE", "value": "recreate" }
```

### 16-4. 将来 `readonlyRootFilesystem=true` + ボリュームへ戻すとき

戻す作業は**環境変数 2 つとタスク定義のボリューム設定だけ**で済む。
`entrypoint.sh` / `base/Dockerfile` の変更は不要。

| 設定 | 現行 (ボリューム無し) | readonly 化後 |
|---|---|---|
| `readonlyRootFilesystem` | `false` | `true` |
| `configuration` / `tmp` / `data` のボリューム | 無し | **必須** (5-3 章) |
| `CONFIG_SEED_MODE` | `skip` | **`overwrite`** |
| `EXTRASLB_TLS_CONFIG_MODE` | `auto` | `auto` (変更不要) |
| `EXTRASLB_HISTORY_MODE` | `rotate` | `rotate` (変更不要) |

`entrypoint.sh` の一時ファイル置き場の自動選択 (④) と
履歴ディレクトリの事前作成 + 実書き込み検証 (③) が、そのとき初めて本領を発揮する。

---

## 17. 現行構成での検証手順

### 17-1. イメージの検証 (ビルド直後)

```bash
# ※ $JBOSS_HOME はコンテナ内で展開させる (ホスト側では未定義なので sh -c で包む)

# ★ イメージに履歴が残っていないこと (この構成での最重要チェック)
docker run --rm --entrypoint sh <image> -c 'ls -la "$JBOSS_HOME/standalone/configuration"' \
  | grep standalone_xml_history && echo "NG: イメージに履歴が残っている" || echo "OK"

# Elytron 設定がビルド時に入っていること
docker run --rm --entrypoint sh <image> -c \
  'grep -c extraslb-client-ssl-context "$JBOSS_HOME/standalone/configuration/standalone.xml"'

# configuration の所有者が実行ユーザーであること
docker run --rm --entrypoint sh <image> -c 'ls -ln "$JBOSS_HOME/standalone/configuration"' | head
```

### 17-2. 起動ログの確認

正常時はこうなる (ビルド時適用済みの場合)。

```
==> [entrypoint] configuration はマウントされていません (イメージの overlayfs 上で動作)
==> [entrypoint] standalone.xml に extraslb-client-ssl-context が既に存在するため JBoss CLI をスキップします
==> [entrypoint] standalone_xml_history/current は空です (履歴ローテーションは発生しません)
==> [entrypoint] 履歴ディレクトリの rename 検査: OK (JBoss 側のローテーションも成功します)
==> [entrypoint] preflight OK. starting JBoss EAP
```

* `rename 検査: NG` が出る → イメージにまだ履歴が残っている (16-1 の 2 番目を入れる)
* `configuration はマウントされたボリュームです` が出る → 想定と違う。タスク定義を確認

### 17-3. 起動後

```bash
# 履歴関連のエラーが出ていないこと
docker logs <container> | grep -E 'WFLYCTL0056|WFLYCTL0414|WFLYCTL0082' || echo "OK"

# :reload してもローテーションが失敗しないこと (14-2 の効果確認)
docker exec <container> $JBOSS_HOME/bin/jboss-cli.sh -c ':reload'
docker logs <container> | grep -E 'WFLYCTL0056|WFLYCTL0414' || echo "OK: reload 後もエラー無し"
```

---

## 18. 現行構成のチェックリスト

- [ ] イメージ内に `standalone/configuration/standalone_xml_history` が **無い**
- [ ] `standalone.xml` に `extraslb-client-ssl-context` が**ビルド時点で**入っている
- [ ] `configuration` 配下の所有者がイメージの `USER` と一致している
- [ ] **タスク定義で `user` を指定していない** (指定するなら所有権を合わせている)
- [ ] `CONFIG_SEED_MODE=skip`、または seed をビルド時適用の後ろで取得している
- [ ] 起動ログに `rename 検査: OK` が出ている
- [ ] 起動ログに WFLYCTL0056 / WFLYCTL0414 / WFLYCTL0082 が出ていない
- [ ] `describe-tasks` の `stoppedReason` / `exitCode` を確認済み (15 章手順 0)
- [ ] ヘルスチェックの `startPeriod` / `healthCheckGracePeriodSeconds` が起動時間に対して十分

---

## 19. 検証状況 — 何を確認し、何を確認していないか

**この調査で「確認済み」と「未確認 (仮説のまま)」を明示的に分ける。**
未確認の項目は、実環境での確認手順を必ず併記する。

### 19-1. 確認済み — 一次情報で裏付けたもの

| 対象 | 確認方法 | 結果 |
|---|---|---|
| `createHistoryDirectory()` / `successfulBoot()` / `forcedMove()` / `copyFile()` の挙動 | `wildfly-core` の `ConfigurationFile.java` / `FilePersistenceUtils.java` を取得し**逐語で確認** | 2 章に引用したとおり。WARN の後にブートが継続し、`copyFile()` で落ちる経路が確定 |
| ログ ID とレベル | `ControllerLogger.java` の `@Message(id=…)` / `@LogMessage(level=…)` を直接確認 | **WFLYCTL0414 = WARN** / WFLYCTL0056 = ERROR / WFLYCTL0082 = `ConfigurationPersistenceException` / WFLYCTL0051 = `IllegalStateException` |
| `current` が空なら rename が走らないこと | `currentHistoryFiles.length > 0` の条件を確認 (★(A)) | **本修正の中核となる前提が成立** |
| ブート経路の履歴依存 | `determineMainFile` / `determineBootFile` / `findMainFileFromSnapshotPrefix` / `findSnapshotWithPrefix` / `findMainFileFromBackupSuffix` を全件確認 | `-c standalone.xml` では**履歴に一切依存しない**。`-c last/initial/boot/vN` のみ依存 (→ [shortest-fix-safety-analysis.md](./shortest-fix-safety-analysis.md) C1) |
| overlayfs がディレクトリ rename に EXDEV を返すこと | **Linux カーネル公式ドキュメント** `Documentation/filesystems/overlayfs.rst` (Renaming directories / whiteout / opaque) | 既定で EXDEV。`redirect_dir` は Docker/containerd で既定 off |
| `Files.move` の EXDEV フォールバック | JDK `sun.nio.fs.UnixCopyFile#move` の仕様 (rename → mkdir+rmdir → 非空なら ENOTEMPTY) | `DirectoryNotEmptyException` になる経路が確定 |
| `entrypoint.sh` の文法 | `bash -n` | OK |

### 19-2. 確認済み — スタブ環境での動作テスト

**実際の JBoss EAP は使わず**、次を模したスタブで `entrypoint.sh` を実行した。

* 偽 `jboss-cli.sh` — `embed-server` と同じ副作用を再現
  (`standalone_xml_history/current/standalone.v1.xml` を作り、`standalone.xml` を書き換える)
* 偽 `standalone.sh` — `createHistoryDirectory()` の判定を再現
  (`current` が非空なら「rename を試みる = 危険」として非 0 終了)

| テストケース | 期待 | 結果 |
|---|---|---|
| ECS 初回起動相当 (CLI あり・既定 `rotate`) | `current` を退避して空に → rename 発生せず起動 | ✅ exit 0 |
| 再起動相当 (`standalone.xml` に設定済み) | `auto` で CLI をスキップ | ✅ CLI 実行なし |
| Compose 相当 (イメージ由来の非空 `current` が既にある) | 退避して空に → 起動 | ✅ exit 0・退避物を保全 |
| `EXTRASLB_HISTORY_MODE=off` (従来動作) | **障害が再現する** | ✅ exit 42 (rename が試みられる) |
| `EXTRASLB_HISTORY_MODE=recreate` | 履歴ツリーを作り直しつつ過去の `<timestamp>` を保全 | ✅ 保全を確認 |
| `EXTRASLB_HISTORY_AUTO_RECREATE=false` | probe を実行しない | ✅ 実行なし |
| rename probe が NG になる環境の模擬 (`stat` を差し替え) | 自動で作り直し、履歴は保全 | ✅ 保全を確認 |
| seed 未復元 (`standalone.xml` が無い) | 順序の誤りを明示して `exit 1` | ✅ 診断ダンプ付き |
| `EXTRASLB_TLS_CONFIG_MODE` / `EXTRASLB_HISTORY_MODE` の不正値 | 即 `exit 1` | ✅ |
| `/tmp` 以外への一時ファイル退避 | 書き込み可能ディレクトリを自動選択 | ✅ `standalone/tmp` を選択 |

### 19-3. ★ 未確認 — 実環境で確認が必要なもの

**この環境では Docker デーモンが起動しておらず、
また JBoss EAP イメージの取得には `registry.redhat.io` へのログインが必要なため、
実イメージ・実 ECS タスクでの再現と確認は行えていない。**
以下は**すべて仮説**であり、確認手順とセットで扱うこと。

| # | 未確認の仮説 | なぜ仮説のままか | 確認手順 |
|:--:|---|---|---|
| U1 | **イメージに `configuration/standalone_xml_history` が焼き込まれている** | 実イメージを見ていない。ビルド時に CLI / サーバを起動していれば入るが、していなければ入らない | [shortest-fix 4-4](./shortest-fix-safety-analysis.md#4-4-反証可能な判定--適用前に必ずこれを見る) の 1 コマンド。**ここが「無し」なら EXDEV 説は棄却され、原因は EACCES に絞られる** |
| U2 | **WFLYCTL0414 の原因が EXDEV である** | ログの WFLYCTL0056 の原因例外を見ていない | 4-1 章。`DirectoryNotEmptyException` なら EXDEV、`AccessDeniedException` なら権限 |
| U3 | **ECS の異常終了が履歴以外の原因 (15-a〜e) である** | `stoppedReason` / `exitCode` を見ていない | [15 章 手順 0](#15-この構成でecs-だけ異常終了するときの切り分け)。**最優先で実施すること** |
| U4 | **ビルド時の Elytron 設定適用 (`base/Dockerfile`) が通る** | ビルドを実行していない。`embed-server` は `standalone/log` / `tmp` / `data` へ書くため、リンク化前に置く必要がある | `docker build` して `[base] applied Elytron outbound TLS configuration at build time` が出ること |
| U5 | **`stat -c %i` が実行イメージに存在する** | UBI9 (GNU coreutils) には含まれるが、実イメージを確認していない | probe が使えない場合は `WARN: 履歴ディレクトリの rename 検査を実施できませんでした` を出して**安全側に倒す** (起動は継続) |
| U6 | **`configuration` の所有者と実行ユーザーが一致している** | 実イメージ・実タスク定義を見ていない | [15-(a)](#a-タスク定義の-user-指定とイメージの-user-の不一致-最有力) の `id` / `ls -ln` |
| U7 | **`SERVER_CONFIG` が `last`/`initial`/`boot`/`vN` でない** | タスク定義を見ていない | [shortest-fix C1](./shortest-fix-safety-analysis.md#c1-server_config-が-last--initial--boot--vn--スナップショット名でない-唯一の破壊ケース) |

### 19-4. 実環境で最初にやること (優先順)

```
1. describe-tasks で stoppedReason / exitCode を取る            → U3 (異常終了の系統確定)
2. ログの WFLYCTL0056 の原因例外を見る                          → U2 (EXDEV か EACCES か)
3. イメージに standalone_xml_history があるか見る                → U1 (最短の打ち手が効くか)
4. タスク定義の user と configuration の所有者を突き合わせる      → U6 (最有力の異常終了原因)
5. SERVER_CONFIG を確認する                                     → U7 (最短の打ち手の唯一の破壊条件)
```

**1〜5 はすべて読み取りのみで、いずれも 1 コマンドで済む。**
この 5 つが埋まれば、本ドキュメントの仮説は確定または棄却され、
打つべき手が [14 章のマトリクス](#14-これまでの対処法は有効か--有効性マトリクス) と
[shortest-fix 7 章](./shortest-fix-safety-analysis.md#7-絶対に大丈夫にするための最小セット)
から一意に決まる。

### 19-5. 実装の位置づけ

`base/scripts/entrypoint.sh` の修正は
**U1〜U7 のどれが真であっても安全側に働く**ように設計してある。

| 仮説の真偽 | 実装の挙動 |
|---|---|
| U1 が真 (イメージに履歴あり) | probe が NG → 自動で作り直し → EXDEV 解消 |
| U1 が偽 (履歴なし) | probe が OK → 何もしない (無駄な処理をしない) |
| U2 が EACCES だった | 事前の実書き込み検証で **WFLYCTL0082 より前に `FATAL: … に書き込めません`** を出す |
| U5 が偽 (`stat` なし) | probe をスキップし警告のみ。`current` は空にしてあるので起動は継続 |
| U3 が履歴以外だった | 履歴由来のノイズが消え、真の原因がログで読みやすくなる |

**ただし「安全側に働く」ことと「異常終了が直る」ことは別である** (4 章)。
U3 の確定だけは、実環境での確認が必須である。
