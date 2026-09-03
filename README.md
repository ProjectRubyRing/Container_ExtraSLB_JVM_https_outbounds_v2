# JBoss EAP 8.1 / 自己署名証明書によるアウトバウンド HTTPS 設定

ECS 上の JBoss EAP 8.1 コンテナ (フロント / バック) にデプロイした Java アプリから、
extraslb (自己署名証明書) をはじめとする複数の提供元を経由して
外部へ HTTPS REST 通信するためのコンテナ実装一式。

採用方式: **ベースイメージへの証明書埋め込み (BuildKit Secrets)**。
他方式との比較・移行方針は [docs/certificate-management-strategies.md](docs/certificate-management-strategies.md) を参照。

証明書は提供元ごとに `secrets/certs/<name>/cacert.crt` として配置し、
`certs` ディレクトリ配下をまとめて **1 つの BuildKit Secret (`id=cacerts`)** として渡す。
**複数ソースを 1 つのトラストストアへまとめて取り込む**ため、
ソースが増えても Dockerfile / docker build コマンド / JBoss CLI / entrypoint の
いずれも変更不要 (→ [証明書ソースを追加する手順](#証明書ソースを追加する手順))。

## 構成

```
secrets/                               # 受領した証明書の置き場 (コミット禁止・.gitignore 済み)
  certs/                               #   ここより下がまとめて 1 つのシークレットになる
    extraslb/cacert.crt                #     提供元ごとにディレクトリを分ける
    others/cacert.crt                  #     ディレクトリ名がトラストストア上のエイリアス接頭辞になる
  cacerts-bundle.tar                   #   ヘルパーが生成する受け渡し用アーカイブ (ビルド後は削除可)
scripts/cacert-secret-args.sh          # secrets/certs を 1 つの tar にまとめ docker build の --secret 引数を生成
base/                                  # ベースイメージ (証明書関連を一元管理)
  Dockerfile                           # BuildKit Secret 1 つ (id=cacerts) を受け取りトラストストア生成
  scripts/build-truststore.sh          # cacerts ベースの PKCS12 トラストストア組み立て (アーカイブ展開・複数ソース・PEM/DER 自動判別・チェーン対応)
  scripts/entrypoint.sh                # 起動時: JBoss CLI 実行 → JVM プロパティ付きで EAP 起動
  jboss-cli/configure-outbound-tls.cli # Elytron の key-store / trust-manager / client-ssl-context 定義
front/Dockerfile                       # ベースを継承し WAR を配置するだけ
back/Dockerfile                        # 同上
docs/certificate-management-strategies.md
docs/standalone-xml-history-ecs-vs-compose.md   # ECS だけ異常終了する履歴ローテーション問題の原因と修正
docs/shortest-fix-safety-analysis.md            # 「最短の打ち手」の安全性・十分性の論理検証
```

## 信頼設定の 2 層構え (どの HTTP クライアントでも動作させるため)

| 層 | 設定箇所 | 効く対象 |
|----|----------|----------|
| Elytron `default-ssl-context` | JBoss CLI (起動時に entrypoint が適用) | `SSLContext.getDefault()` を使う実装全般 (JAX-RS Client, MicroProfile REST Client, HttpsURLConnection 等) |
| `javax.net.ssl.trustStore` 系 JVM システムプロパティ | entrypoint が `standalone.sh` のサーバ引数として付与 | システムプロパティから独自に SSLContext を組み立てるライブラリ (Apache HttpClient の一部設定等) |

両者は同一のトラストストア (`/opt/app/security/extraslb-truststore.p12`) を参照する。
トラストストアは **JDK cacerts のコピーに受領した全ソースの CA 証明書を追加**したものなので、
パブリック CA 宛の既存 HTTPS 通信 (AWS SDK 等) は壊れない。
証明書ソースが何個になっても取り込み先は常にこの 1 ファイルであり、
JVM システムプロパティ側・Elytron 側のどちらにも同時に反映される。

> アプリ側で `SSLContext` やトラストストアを明示的に自前構築している場合は、
> 同パス (`EXTRASLB_TRUSTSTORE_PATH` 環境変数で参照可) を読むように実装すること。

## ビルド手順

入力は提供元ごとの CA 証明書 **`cacert.crt`**。`secrets/certs/<name>/cacert.crt` の構成で配置する。
`.crt` は PEM (Base64 テキスト) / DER (バイナリ) のどちらの形式でもよく、
`build-truststore.sh` がファイルの中身を見てソースごとに自動判別する (拡張子では判定しない)。
PEM でチェーンが連結されている場合は全証明書を取り込む。

```bash
# 0. 各提供元から受領した cacert.crt を配置
#    ※ secrets/ はリポジトリにコミットしないこと (.gitignore 済み)
mkdir -p secrets/certs/extraslb secrets/certs/others
cp /path/to/extraslb-cacert.crt secrets/certs/extraslb/cacert.crt
cp /path/to/others-cacert.crt   secrets/certs/others/cacert.crt

# 形式の事前確認 (任意)
file secrets/certs/extraslb/cacert.crt                     # "PEM certificate" or "data" (DER)
keytool -printcert -file secrets/certs/extraslb/cacert.crt # PEM/DER どちらでも内容を表示できる

# 1. registry.redhat.io へログイン (EAP 8.1 イメージ取得に必要)
docker login registry.redhat.io

# 2. ベースイメージのビルド
#    ヘルパーが secrets/certs をまとめた tar を作り --secret 引数を生成する。
#    ソースが何個でもコマンドはこの 1 行のまま。
DOCKER_BUILDKIT=1 docker build \
  $(bash scripts/cacert-secret-args.sh) \
  -t eap81-extraslb-base:1.0 \
  base/

#    ヘルパーを使わない場合 (やっていることは同じ)
#    ※ certs 配下を丸ごと固めるため、証明書以外のファイル (README, .DS_Store 等) を
#      置かないこと。ヘルパーは *.crt / *.pem だけを選んで固める。
tar -cf secrets/cacerts-bundle.tar -C secrets/certs .
DOCKER_BUILDKIT=1 docker build \
  --secret id=cacerts,src=secrets/cacerts-bundle.tar \
  -t eap81-extraslb-base:1.0 \
  base/

# 3. フロント / バックのビルド (WAR は各 target/ に配置済みの前提)
docker build --build-arg BASE_IMAGE=eap81-extraslb-base:1.0 -t myapp-front:1.0 front/
docker build --build-arg BASE_IMAGE=eap81-extraslb-base:1.0 -t myapp-back:1.0  back/
```

CI/CD (CodeBuild 等) では各 `cacert.crt` を Parameter Store から取得して `secrets/certs/` に並べる。
**ビルドコマンド側はソースが増えても不変**で、取得処理を 1 行足すだけでよい:

```bash
mkdir -p secrets/certs/extraslb secrets/certs/others

# PEM 形式で格納している場合
aws ssm get-parameter --name /extraslb/cacert --with-decryption \
  --query Parameter.Value --output text > secrets/certs/extraslb/cacert.crt
aws ssm get-parameter --name /others/cacert --with-decryption \
  --query Parameter.Value --output text > secrets/certs/others/cacert.crt

# DER (バイナリ) の場合は Base64 で格納しておき、取得後にデコードする
#   aws ssm get-parameter ... --output text | base64 -d > secrets/certs/<name>/cacert.crt

DOCKER_BUILDKIT=1 docker build $(bash scripts/cacert-secret-args.sh) ... base/
rm -rf secrets     # 証明書と受け渡し用 tar をまとめて破棄
```

### 証明書ソースを追加する手順

**配置するだけでよい** (例: `newsvc` を追加する場合):

1. `secrets/certs/newsvc/cacert.crt` を配置する
2. 上記「2.」のコマンドでベースイメージをビルドし直す

`base/Dockerfile` も `docker build` コマンドも変更不要。
`secrets/certs` 配下が丸ごと 1 つのシークレット (`id=cacerts`) として渡され、
`build-truststore.sh` がサブディレクトリ名をソース名として全件取り込むため。

> **なぜ tar でまとめるのか**: BuildKit のシークレットは**ディレクトリをマウントできない**
> ([moby/buildkit#970](https://github.com/moby/buildkit/issues/970) は未解決) ため、
> `--secret id=cacerts,src=secrets/certs` のようにディレクトリを直接指定することはできない。
> そこで `certs` ディレクトリを 1 ファイル (tar) に詰めて 1 つのシークレットとして渡し、
> 展開とソース列挙をビルドコンテナ側 (`build-truststore.sh`) で行うことで、
> **Dockerfile のマウント行をソース数に依存させない**構成にしている。
> tar はビルド時のみマウントされるシークレットであり、イメージレイヤーには残らない。
> アーカイブの作成にはビルドホストの `tar` (Windows は Git Bash 同梱のもの)、
> 展開にはベースイメージ内の `tar` を使う。UBI9 ベースの標準イメージには
> `tar` が含まれるが、`*-minimal` 系へ差し替える場合は導入が必要
> (未導入なら `build-truststore.sh` がその旨を出してビルドを止める)。

証明書を渡し忘れたビルドは `required=true` によりその場で失敗する
(証明書の入っていないイメージが黙って完成することはない)。

| 決めごと | 内容 |
|----------|------|
| ディレクトリ名 = ソース名 | `secrets/certs/<name>/cacert.crt` |
| シークレット ID | `cacerts` (固定・1 つだけ) |
| マウント先 | `/run/secrets/cacerts.tar` (中身は `<name>/cacert.crt`) |
| トラストストア上のエイリアス | `<name>-ca-1`, `<name>-ca-2`, … (PEM チェーンは 1 枚ずつ連番) |
| 1 ソースに複数ファイル | `<name>/` 直下の `*.crt` / `*.pem` を全て取り込み、連番は継続する |

## 動作確認

ビルドログの末尾にソースごとの取り込み結果が出力される。
ここに想定したソース名が全て並んでいるかを確認する
(並んでいなければ `secrets/certs/<name>/` への配置漏れ。
ヘルパー実行時の `==> certificate sources: ...` でも確認できる):

```
==> Done. 3 of 3 certificate(s) imported into /opt/app/security/extraslb-truststore.p12
      extraslb: 2 imported / 0 skipped (duplicate) <- extraslb/cacert.crt
      others: 1 imported / 0 skipped (duplicate) <- others/cacert.crt
```

```bash
# トラストストアに証明書が入っているか (alias は <name>-ca-1, <name>-ca-2, ...)
docker run --rm --entrypoint bash eap81-extraslb-base:1.0 -c \
  'keytool -list -keystore $EXTRASLB_TRUSTSTORE_PATH -storepass changeit | grep -E "^(extraslb|others)-ca-"'
# cacert.crt / 受け渡し用 tar がイメージに残っていないこと
docker run --rm --entrypoint bash eap81-extraslb-base:1.0 -c \
  'ls /run/secrets/ 2>/dev/null; echo "(空であること)"'
docker history eap81-extraslb-base:1.0   # cacert.crt の COPY レイヤーが無いこと

# 起動時の JBoss CLI 適用と EAP 起動
docker run --rm -p 8080:8080 myapp-front:1.0
#   → ログに "Applying Elytron outbound TLS configuration" と CLI の success が出力される

# 起動後、Elytron 設定を確認 (別ターミナル)
docker exec <container> $JBOSS_HOME/bin/jboss-cli.sh -c \
  '/subsystem=elytron/client-ssl-context=extraslb-client-ssl-context:read-resource'
docker exec <container> $JBOSS_HOME/bin/jboss-cli.sh -c \
  '/subsystem=elytron:read-attribute(name=default-ssl-context)'
```

## 環境変数 (ECS タスク定義で上書き可能)

| 変数 | 既定値 | 用途 |
|------|--------|------|
| `EXTRASLB_TRUSTSTORE_PATH` | `/opt/app/security/extraslb-truststore.p12` | トラストストアのパス |
| `EXTRASLB_TRUSTSTORE_PASSWORD` | `changeit` | トラストストアのパスワード (公開証明書のみのため整合性チェック用途) |
| `EXTRASLB_TRUSTSTORE_TYPE` | `PKCS12` | トラストストア形式 |
| `SERVER_CONFIG` | `standalone.xml` | EAP のサーバ設定ファイル |
| `JBOSS_BIND_ADDRESS` | `0.0.0.0` | パブリックインターフェースのバインドアドレス |
| `JBOSS_CONF_DIR` | `${JBOSS_HOME}/standalone/configuration` | configuration ディレクトリ (configuration-seed 方式と同じ変数名) |
| `EXTRASLB_TLS_CONFIG_MODE` | `auto` | `auto` = `standalone.xml` に設定済みなら起動時の JBoss CLI をスキップ / `always` / `skip` |
| `EXTRASLB_HISTORY_MODE` | `rotate` | `standalone_xml_history/current` の扱い。`rotate` = 退避して空にする / `recreate` = 履歴ツリーごと作り直す / `purge` / `off` (従来動作) |
| `EXTRASLB_HISTORY_AUTO_RECREATE` | `true` | `rename(2)` が通らないと実測できた場合にだけ履歴ツリーを自動で作り直す (overlayfs の merged ディレクトリ対策) |
| `EXTRASLB_STRICT_PREFLIGHT` | `true` | 書き込み検証の失敗で起動を止めるか |
| `EXTRASLB_TMP_DIR` | (自動選択) | CLI 一時ファイルの置き場所 (`/tmp` が read-only な環境向け) |

> `EXTRASLB_TLS_CONFIG_MODE` / `EXTRASLB_HISTORY_MODE` は、
> **configuration-seed 方式と併用したときに ECS だけ異常終了する**問題への対応で追加したもの。
> 背景・原因・修正箇所の詳細は
> [docs/standalone-xml-history-ecs-vs-compose.md](docs/standalone-xml-history-ecs-vs-compose.md) を参照。
>
> 同ドキュメントは 2 つの構成を扱っている。
> - **0〜12 章**: `readonlyRootFilesystem=true` + `configuration` にタスクローカルボリューム
> - **13〜18 章 (構成別 追補)**: `readonlyRootFilesystem=false` + ボリューム無し + seed 有効
>   — この構成では **イメージから `standalone_xml_history` を削除すること**と
>   **Elytron 設定のビルド時適用**が要になる (overlayfs の merged ディレクトリは
>   権限が正しくても `rename` が通らないため)

## configuration-seed 方式との併用

`configuration-seed` 方式 (起動時に `configuration-seed` → `configuration` を書き戻す) と
併用する場合、**seed の書き戻しより後に本 entrypoint が動く**ようにする。

```dockerfile
ENTRYPOINT ["/usr/local/bin/efs-entrypoint.sh"]   # 1. configuration-seed の書き戻し
CMD        ["/usr/local/bin/entrypoint.sh"]       # 2. Elytron 設定 + 履歴正規化 + standalone.sh
```

逆順にすると CLI が書いた `standalone.xml` を seed の `cp -R` が上書きして設定が消える。
順序を誤った場合は entrypoint がその旨を出力して `exit 1` する。
詳細: [docs/standalone-xml-history-ecs-vs-compose.md](docs/standalone-xml-history-ecs-vs-compose.md)

## 証明書ローテーション時の手順

1. 提供元から新しい `cacert.crt` を受領し、CI の一次保管場所 (Parameter Store 等) を更新
   (更新するのは該当ソースのパラメータのみ。他ソースの証明書はそのまま)
2. ベースイメージを再ビルド → フロント / バックを再ビルド
3. ECS サービスを新イメージでローリングデプロイ

ローテーション頻度が高くなった場合は、起動時に Parameter Store から取り込む方式への
移行を推奨 (詳細: docs/certificate-management-strategies.md 方式 3)。
