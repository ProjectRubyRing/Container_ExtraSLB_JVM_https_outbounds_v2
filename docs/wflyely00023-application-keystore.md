# WFLYELY00023 (application.keystore does not exist) の原因と対処

```
WARN [org.wildfly.extension.elytron] (MSC service thread 1-1) WFLYELY00023:
     KeyStore file '/opt/jboss-eap/standalone/configuration/application.keystore'
     does not exist. Used blank.
```

**結論を先に**

| 問い | 答え |
|------|------|
| 自己署名証明書の登録・その証明書を使ったアウトバウンド HTTPS に影響するか | **しない**。別リソース。実測で確認済み (§3) |
| JDK 同梱ルート証明書によるアウトバウンド HTTPS に影響するか | **しない**。同上 |
| 本プロジェクトの設定が原因か | **違う**。EAP 標準設定 (`applicationKS`) が単独で出す。`default-ssl-context` を設定しなくても、`https-listener` を消しても出る (§2) |
| 実害は | インバウンド HTTPS (8443) を使う場合のみ関係する。しかも EAP が初回接続時に自己署名証明書を自動生成するため通常は動く。**読み取り専用ファイルシステムだと自動生成が失敗する**点だけは実害になり得る (§4) |
| 抑制方法 | EAP が自動生成するはずのキーストアを**ビルド時に先に作っておく** (§5) |

---

## 1. 何のキーストアなのか

EAP / WildFly の標準 `standalone.xml` には、**インバウンド (サーバ側) HTTPS**
のための TLS リソースが最初から入っている。

```xml
<key-store name="applicationKS">
    <credential-reference clear-text="password"/>
    <implementation type="JKS"/>
    <file path="application.keystore" relative-to="jboss.server.config.dir"/>
</key-store>
<key-manager name="applicationKM" key-store="applicationKS"
             generate-self-signed-certificate-host="localhost">
    <credential-reference clear-text="password"/>
</key-manager>
<server-ssl-context name="applicationSSC" key-manager="applicationKM"/>
...
<https-listener name="https" socket-binding="https" ssl-context="applicationSSC" .../>
```

本プロジェクトが追加するのは**アウトバウンド (クライアント側)** の系統で、
名前空間もリソース種別も完全に別である。

| | 本プロジェクト (アウトバウンド) | 警告の出どころ (インバウンド) |
|---|---|---|
| キーストア | `extraslb-trust-store` (CA 証明書のみ・秘密鍵なし) | `applicationKS` (サーバ秘密鍵) |
| マネージャ | `extraslb-trust-manager` (**trust**-manager) | `applicationKM` (**key**-manager) |
| SSL コンテキスト | `extraslb-client-ssl-context` (**client**) | `applicationSSC` (**server**) |
| 用途 | 相手サーバの証明書を検証する | 自分の証明書を相手に提示する |
| 実体ファイル | `/opt/app/security/extraslb-truststore.p12` (ビルド時に生成・イメージに同梱) | `standalone/configuration/application.keystore` (**同梱されていない**) |

`applicationKS` が「空 (blank)」になっても、失われるのは
**サーバが提示する鍵**であって、**相手を検証するための信頼アンカー**ではない。
アウトバウンド通信の信頼判断は `extraslb-trust-store` が単独で担っている。

## 2. なぜ毎起動出るのか (タイミング)

2 つの事実の組み合わせで発生する。

1. **`application.keystore` はディストリビューションに同梱されていない。**
   Elytron は「初回のインバウンド HTTPS ハンドシェイク時」に自己署名証明書を
   遅延生成する。生成前は当然ファイルが無い。
2. **Elytron の `key-store` リソースは ACTIVE な MSC サービス**で、
   誰も参照していなくてもブートのたびに起動する。
   ログの `(MSC service thread 1-1)` はこれを示している。

したがって「ファイルが無い状態でのブート」のたびに必ず出る。
コンテナは起動のたびにイメージの初期状態へ戻るので、**毎起動出続ける**。

実測 (WildFly 36 / EAP 8.1 と同系の Elytron。以下すべて実行して確認):

| 条件 | WFLYELY00023 |
|------|--------------|
| 素の標準設定でブート | **出る** |
| `https-listener` を削除した設定でブート | **出る** (誰も参照していなくても起動するため) |
| `default-ssl-context` に client-ssl-context を設定 | 出る / 出ないに影響しない |
| `embed-server` (entrypoint / ビルド時の CLI 適用) | **出る** (組み込みサーバも同じサービスを起動する) |
| `application.keystore` を事前に置いてブート | **出ない** |

> **本プロジェクトの変更との関係**
> この警告自体は本プロジェクトの Elytron 設定とは独立している。ただし
> **出現箇所は変わる**。起動時 CLI (`EXTRASLB_TLS_CONFIG_MODE=always`) では
> embed-server の分と本ブートの分で 1 起動につき 2 回出る。
> 現在の既定 (ビルド時適用 + `auto`) では、ビルドログに 1 回・起動ログに 1 回になる。

## 3. 通信への影響が無いことの実測

同一ブート — つまり **WFLYELY00023 が出ているそのサーバ** — の上で、
`default-ssl-context` 経由のアウトバウンド HTTPS を 2 種類実行した。

```
01:00:01,404 WARN  [org.wildfly.extension.elytron] WFLYELY00023:
     KeyStore file '.../application.keystore' does not exist. Used blank.
...
defaultSSLContext = org.wildfly.security.ssl.DelegatingSSLContext
OUTBOUND https://localhost:9443/   -> HTTP 200 peer=CN=localhost  issuer=O=Probe, CN=Probe Root CA
OUTBOUND https://www.google.com/   -> HTTP 200 peer=CN=www.google.com issuer=CN=WR2, O=Google Trust Services, C=US
```

- 1 行目: **自己署名ルート CA が発行したサーバ**へ接続 → 成功
  (トラストストアへ取り込んだ CA で検証できている)
- 2 行目: **パブリック CA のサーバ**へ接続 → 成功
  (JDK cacerts のコピーが土台になっているため引き続き検証できている)

`SSLContext.getDefault()` が Elytron の `DelegatingSSLContext`
(= `extraslb-client-ssl-context`) になっていることも同時に確認できる。
`applicationKS` が blank であることは、この経路に一切現れない。

## 4. 放置した場合に唯一残るリスク

インバウンド HTTPS (8443) を使う場合のみ関係する。

- 通常のファイルシステム: 初回接続時に EAP が自己署名証明書を生成して動く
  (`WFLYELY01084` がその予告)。ただし**コンテナ / タスクごとに別の証明書**になる。
- `readonlyRootFilesystem=true` + `configuration` が書き込み不可:
  遅延生成が失敗し、**8443 のハンドシェイクが失敗する**。

本プロジェクトの構成では ALB で TLS 終端し、コンテナは 8080 で受けるため
通常は影響しないが、対処 (§5) はこの穴も同時に塞ぐ。

## 5. 採用した対処

**EAP が自分で作るはずだったキーストアを、ビルド時に先に作ってイメージへ入れる。**

実装: [`base/scripts/provision-application-keystore.sh`](../base/scripts/provision-application-keystore.sh)

生成内容は Elytron の遅延生成と同一形状にしてある (実測して合わせた):

| 項目 | 値 |
|------|-----|
| エイリアス | `server` |
| 識別名 | `CN=<generate-self-signed-certificate-host の値>` (既定 `localhost`) |
| 鍵 / 署名 | RSA 2048bit / SHA256withRSA |
| 有効期間 | 3650 日 |
| ストア形式 | `<implementation type>` の値 (既定 `JKS`) |
| ストアパスワード | `credential-reference clear-text` の値 (鍵パスワードも同じ) |
| 拡張 | SubjectKeyIdentifier のみ (SAN は付かない) |

呼び出し箇所は 2 か所。既にファイルがあれば何もしない (冪等)。

| 箇所 | 目的 | 無効化 |
|------|------|--------|
| `base/Dockerfile` | イメージへ埋め込む。**Elytron 設定 (embed-server) より前**に置いてあるのでビルドログからも警告が消える | `--build-arg PROVISION_APPLICATION_KEYSTORE=false` |
| `base/scripts/entrypoint.sh` (5.) | configuration-seed / ボリューム差し替え / `SERVER_CONFIG` 変更 / `APPLY_TLS_CONFIG_AT_BUILD=false` で取りこぼした場合の補完 | `EXTRASLB_APP_KEYSTORE_MODE=skip` |

### 安全側に倒すための判定条件

「単なる警告」を潰しに行って**ブート失敗**や**不正な信頼アンカーの混入**を
作り出しては本末転倒なので、次を全て満たす `key-store` だけを対象にする。

1. `<file relative-to="jboss.server.config.dir">` であること
2. `path` が式 (`${...}`) やディレクトリ区切りを含まない単純なファイル名であること
3. 実ファイルがまだ存在しないこと
4. `credential-reference clear-text` が式ではなくリテラルであること
   — パスワードを確定できないまま作ると、**警告がブート失敗 (キーストア読み込み
   エラー) に悪化する**
5. **`generate-self-signed-certificate-host` を持つ `key-manager` から
   参照されていること**
   — これが本質的な条件。「EAP 自身が自己署名証明書を生成する対象」だと設定
   ファイルが明言しているものだけを先回りして作るので、動作は EAP の既定と
   完全に等価になる。
   トラストストアを誤って対象にする事故も防げる
   (JDK の `TrustManagerFactory` は `PrivateKeyEntry` のチェーン先頭も
   信頼済み証明書として扱うため、トラストストアに自己署名鍵を作り込むと
   **本物の信頼アンカー汚染**になる)

本プロジェクトが CLI で追加する `extraslb-trust-store` は
`path` が `${env.EXTRASLB_TRUSTSTORE_PATH:...}` という式で `relative-to` も
持たないため、条件 1/2 で確実に除外される。

生成後は設定どおりのパスワード・形式で開き直せるかを検証し、
開けなければ生成物を削除する。スクリプトの失敗でビルドや起動を止めることはしない
(元々「警告が出るだけ」の事象のため)。

### 検証結果

| ケース | 結果 |
|--------|------|
| ベースイメージのビルド | ビルドログに WFLYELY00023 が出ない (embed-server 実行時も) |
| そのイメージで起動 | 起動ログに WFLYELY00023 / WFLYELY01084 が出ない。`WARN` は他要因の分のみ |
| インバウンド HTTPS (8443) | `HTTP 200` / `subject=CN=localhost` で従来どおり応答 |
| 2 回目の実行 (冪等性) | `application.keystore は既に存在します (何もしません)` |
| 起動時にファイルが無い (seed / ボリューム差し替え相当) | entrypoint が生成し、警告が出ない |
| `EXTRASLB_APP_KEYSTORE_MODE=skip` | 生成せず、警告が出る (従来動作)。起動は正常 |
| 不正値 | `FATAL: EXTRASLB_APP_KEYSTORE_MODE の値が不正です: 'bogus' (auto\|skip)` |

## 6. 採用しなかった案

| 案 | 却下理由 |
|----|----------|
| `org.wildfly.extension.elytron` のログレベルを上げる | 同カテゴリの本当に見たい警告 (証明書期限切れ `WFLYELY00024`、キーストア読み込み失敗など) まで消える。原因も残ったまま |
| `applicationKS` / `applicationKM` / `applicationSSC` を CLI で削除する | `https-listener` が `applicationSSC` を参照しているため、順序を誤ると**ブート失敗**する。インバウンド 8443 を使う構成に移行できなくなる。得られるものは警告 1 行の削除だけで、リスクに見合わない |
| `https-listener` ごと削除する | 同上に加え、8443 を使う判断はアプリ側の要件であってベースイメージが決めることではない |
| 起動時に必ず生成する (`always` 相当) | 毎起動 RSA 2048bit 鍵を作るのは無駄。ビルド時に決定的に 1 回作るほうが起動も速く、タスク間で証明書が揃う |

## 7. 補足: 同時に見えることがある WFLYELY00024

```
WARN [org.wildfly.extension.elytron] WFLYELY00024: Certificate
     [cn_baltimore_cybertrust_root,...] in KeyStore is not valid:
     java.security.cert.CertificateExpiredException: NotAfter: Mon May 12 23:59:00 GMT 2025
```

こちらは**本プロジェクトのトラストストア**が出す。JDK の `cacerts` を土台に
している以上、`cacerts` に残っている期限切れルート証明書がそのまま入るため。

**あえて対処していない。** 期限切れのトラストアンカーを取り除くと、
Java の PKIX 検証はトラストアンカー自体の有効期限を検証しないため、
**現在そのルートで検証が通っているチェーンを壊す可能性がある**。
警告 1 行のために既存の疎通を壊すのは割に合わない。
JDK (ベースイメージ) の更新で `cacerts` から消えれば自然に解消する。
