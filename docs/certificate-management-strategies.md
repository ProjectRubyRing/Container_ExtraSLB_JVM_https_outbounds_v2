# extraslb 自己署名証明書の管理方式検討

ECS 上の JBoss EAP 8.1 コンテナ (フロント / バック) から extraslb 経由で外部 HTTPS REST 通信を
行うにあたり、extraslb から受領する CA 証明書 (`cacert.crt`) を
どこで管理し、どのタイミングでコンテナへ取り込むかの方式比較。

> **入力ファイルの前提**: 取り込み対象は提供元ごとの `cacert.crt`。`.crt` は
> PEM (Base64 テキスト) / DER (バイナリ) のどちらの可能性もあるため、
> `build-truststore.sh` は拡張子ではなく中身 (`-----BEGIN CERTIFICATE-----` の有無) で
> 形式を判別する。以下の各方式でもこの前提は共通。
>
> **複数ソースの前提**: extraslb 以外にも自己署名 CA を持つ提供元が増えうるため、
> 証明書は `secrets/certs/<name>/cacert.crt` の構成で管理し、`build-truststore.sh` が
> **全ソースを 1 つのトラストストアへ**取り込む (エイリアスは `<name>-ca-<n>`)。
> 取り込み先が常に 1 ファイルなので、JVM システムプロパティ (`javax.net.ssl.trustStore`) と
> Elytron `default-ssl-context` の両方へ同時に反映され、ソースが増えても
> JBoss CLI / entrypoint 側の変更は発生しない。以下の各方式でこの点は共通。

> **前提となる整理**: トラストストアへ取り込むのは「公開証明書」であり秘密鍵は含まない。
> したがって漏洩リスクという意味での機密性は高くない。管理上の主な関心事は
> **(1) 改ざんされていない正しい証明書を確実に配布すること (完全性)**、
> **(2) 証明書ローテーション (期限切れ・再発行) への追従容易性**、
> **(3) フロント / バック間での設定の一貫性** の 3 点である。

---

## 方式一覧と比較

| # | 方式 | 取り込みタイミング | ローテーション時の作業 | 起動時の外部依存 | 実装・運用コスト | 推奨度 |
|---|------|--------------------|------------------------|------------------|------------------|--------|
| 1 | **ベースイメージ埋め込み (BuildKit Secrets)** ※今回実装 | ベースイメージビルド時 | ベース再ビルド → フロント/バック再ビルド → 再デプロイ | なし | 低 | ◎ (ローテーション頻度が低い場合) |
| 2 | フロント / バック各イメージに個別埋め込み | 各イメージビルド時 | 全イメージを個別に再ビルド | なし | 中 (重複管理) | △ |
| 3 | SSM Parameter Store + ECS `secrets` 注入 → 起動時取り込み | コンテナ起動時 | Parameter 更新 → タスク再起動のみ | Parameter Store (起動時のみ) | 中 | ◎ (ローテーション頻度が高い場合) |
| 4 | Secrets Manager + ECS `secrets` 注入 → 起動時取り込み | コンテナ起動時 | Secret 更新 → タスク再起動のみ | Secrets Manager (起動時のみ) | 中 (コスト高め) | ○ |
| 5 | S3 から entrypoint で取得 → 起動時取り込み | コンテナ起動時 | S3 オブジェクト更新 → タスク再起動 | S3 + IAM + (AWS CLI/SDK をイメージに同梱) | 中〜高 | △ |
| 6 | EFS マウントで共有 | コンテナ起動時 (マウント) | EFS 上のファイル差し替え → タスク再起動 | EFS マウント | 高 (可用性・運用考慮) | △ |

---

## 各方式の詳細

### 方式 1: ベースイメージ埋め込み + BuildKit Secrets 【今回実装】

ベースイメージのビルド環境 (CI/CD パイプライン等) で `cacert.crt` を管理し、
`docker build --secret id=cacerts,src=<certs をまとめた tar>` でビルド時のみ
マウントして keytool でトラストストア化する。
フロント / バックは `FROM ベースイメージ` するだけで証明書設定・entrypoint・JBoss CLI
設定をすべて継承する。

証明書は提供元ごとに `secrets/certs/<name>/cacert.crt` として置き、**`certs` ディレクトリ
配下をまとめて 1 つのシークレット (`id=cacerts`) として渡す**。BuildKit のシークレットは
ディレクトリをマウントできない ([moby/buildkit#970](https://github.com/moby/buildkit/issues/970) は未解決)
ため、`scripts/cacert-secret-args.sh` が `certs` ディレクトリを 1 つの tar に詰めて
`--secret` 引数を生成し、ビルドコンテナ内で `build-truststore.sh` が展開して
サブディレクトリ名をソース名として全件取り込む。
この構造により、**ソースが増減しても Dockerfile・ビルドコマンドはどちらも変更不要**
(`secrets/certs/<name>/cacert.crt` を置く/消すだけ) になる。

> 補足: ディレクトリを直接渡す方法としては named build context を使う
> `--build-context certs=secrets/certs` + `RUN --mount=type=bind,from=certs,...` もあり、
> これも Dockerfile をソース数に依存させずに済む。ただし bind マウントの内容は
> ビルドキャッシュのキーや provenance の対象となり、シークレットとしての扱い
> (キャッシュ・履歴に残さない) からは外れるため、本実装では採用していない。

- **長所**
  - フロント / バックで設定が完全に一致し、修正箇所がベース 1 箇所に集約される。
  - 起動時に外部サービスへの依存がなく、起動が速く障害点が少ない。
    (Parameter Store 障害・IAM 設定ミスで AP が起動不能になる事故がない)
  - BuildKit Secrets により `cacert.crt` 自体はイメージレイヤーに残らない
    (`docker history` やレイヤー展開で参照不可。イメージに残るのは生成後のトラストストアのみ)。
  - イメージ = 環境の完全な再現物となり、イミュータブルインフラの原則に沿う。
  - PEM / DER の差異をビルドスクリプトが吸収するため、extraslb からの受領形式が
    変わっても手順・パイプラインを変更しなくてよい。
  - 証明書ソースが増えても `secrets/certs/<name>/cacert.crt` を置くだけで済み、
    Dockerfile・ビルドコマンド・アプリ側・JBoss 設定側はいずれも無変更。
- **短所**
  - 証明書ローテーション時にベース + 派生イメージすべての再ビルド・再デプロイが必要。
  - ビルド環境 (CI/CD) 側で `cacert.crt` の受け渡し・保管ルールを別途定める必要がある
    (→ CI 上では CodeBuild + Parameter Store / GitHub Actions Secrets 等から
    `secrets/certs/<name>/` へ書き出すのが定石)。
  - 受け渡し用の tar を作る一手間が挟まる (ヘルパーが実施。ビルド後は削除する)。
  - シークレットを渡し忘れたビルドは `required=true` により失敗するが、
    「一部のソースだけ配置し忘れる」ケースはビルドログのソース一覧
    (`==> Done.` 直後のサマリ) で確認する運用が必要。
- **向くケース**: extraslb 証明書の有効期限が長く (1 年以上等)、ローテーションが
  計画的なリリースサイクルに載せられる場合。**まずはこの方式で開始するのが妥当**。

### 方式 2: フロント / バック各イメージへ個別埋め込み

各アプリの Dockerfile それぞれで `--secret` + keytool を実行する方式。

- **長所**: ベースイメージの管理が不要。アプリごとに証明書を変えられる。
- **短所**: 同じ処理がイメージ数だけ重複し、更新漏れ・設定差異(パス、パスワード、
  インポート漏れ)が発生しやすい。extraslb は共通基盤であり、宛先ごとに証明書を
  変える必要性は通常ないため、重複のデメリットだけが残る。
- **結論**: ベースイメージ運用が既にあるなら選ぶ理由は薄い。**非推奨**。

### 方式 3: SSM Parameter Store + ECS secrets 注入 (起動時取り込み)

各 `cacert.crt` の中身を Parameter Store (SecureString) に格納し、ECS タスク定義の
`secrets` で環境変数としてコンテナに注入。entrypoint が環境変数の値をソース名付きの
ファイルへ書き戻し、そのディレクトリを `build-truststore.sh` へ渡してトラストストアを
組み立てる。環境変数はテキストしか運べないため、
**DER (バイナリ) の cacert.crt は Base64 で格納する** (PEM ならそのまま格納できる)。

ソース追加が「Parameter 追加 + タスク定義に `secrets` を 1 要素追加」だけで済み、
イメージの再ビルドすら不要なのが利点 (方式 1 でもソース追加自体は Dockerfile 無変更で
できるが、再ビルド → 再デプロイは必要になる)。

なお下記のとおり `<name>.crt` を並べたディレクトリを渡す形になるが、
`build-truststore.sh` はこのフラット配置と方式 1 の `<name>/cacert.crt` 配置の
どちらも受け付けるため、スクリプトは方式 1 のものをそのまま流用できる。

```jsonc
// ECS タスク定義 (抜粋) — CACERT_<ソース名> の命名で並べる
{
  "containerDefinitions": [{
    "secrets": [
      {
        "name": "CACERT_EXTRASLB",
        "valueFrom": "arn:aws:ssm:ap-northeast-1:123456789012:parameter/extraslb/cacert"
      },
      {
        "name": "CACERT_OTHERS",
        "valueFrom": "arn:aws:ssm:ap-northeast-1:123456789012:parameter/others/cacert"
      }
    ]
  }]
}
```

```bash
# entrypoint.sh への追加分 (トラストストア組み立てを起動時に移す)
# ※ 起動時生成に切り替える場合、EXTRASLB_TRUSTSTORE_PATH は uid=185 が書き込める
#    パス (例: /tmp/extraslb-truststore.p12) に変更すること。
#    ベースイメージ内の既定パスはビルド時生成物として 0444 になっている。
CACERT_DIR="$(mktemp -d)"
for VAR in $(compgen -v | LC_ALL=C grep '^CACERT_'); do
    VALUE="${!VAR}"
    [[ -n "${VALUE}" ]] || continue
    # 環境変数名 CACERT_EXTRASLB -> ソース名 extraslb (エイリアス extraslb-ca-<n>)
    NAME="$(printf '%s' "${VAR#CACERT_}" | tr 'A-Z' 'a-z')"
    if [[ "${VALUE}" == *"-----BEGIN CERTIFICATE-----"* ]]; then
        printf '%s\n' "${VALUE}" > "${CACERT_DIR}/${NAME}.crt"            # PEM はそのまま
    else
        printf '%s' "${VALUE}" | base64 -d > "${CACERT_DIR}/${NAME}.crt"  # DER は Base64 デコード
    fi
done
if compgen -G "${CACERT_DIR}/*.crt" >/dev/null; then
    /usr/local/bin/build-truststore.sh \
        "${CACERT_DIR}" "${EXTRASLB_TRUSTSTORE_PATH}" "${EXTRASLB_TRUSTSTORE_PASSWORD}"
fi
rm -rf "${CACERT_DIR}"
```

- **長所**
  - ローテーションが「Parameter 更新 + ECS サービスの強制新デプロイ」だけで完結し、
    イメージ再ビルドが不要。証明書とアプリのライフサイクルを分離できる。
  - ECS の `secrets` 機能を使えばコンテナ内に AWS CLI/SDK を同梱する必要がなく、
    IAM は taskExecutionRole への `ssm:GetParameters` (+ SecureString なら KMS) 付与のみ。
  - どの環境 (dev/stg/prod) でどの証明書を使うかを Parameter の階層で管理できる。
- **短所**
  - 起動時に Parameter Store への依存が生じる (注入自体は ECS Agent が行うため
    実質的には taskExecutionRole / Parameter 設定ミスが起動失敗要因になる)。
  - 環境変数のサイズ制限に注意 (Parameter Store の advanced tier でも 8KB。
    証明書チェーンが長い場合は分割か S3 検討)。
  - 「いま動いているタスクがどの証明書を持っているか」がイメージタグから追えなくなる
    ため、監査はタスク起動ログ等で担保する必要がある。
- **向くケース**: 自己署名証明書の有効期限が短い / 再発行が頻繁で、
  イメージ再ビルドなしのローテーションが必須要件の場合。**中長期的な本命**。

### 方式 4: Secrets Manager + ECS secrets 注入

方式 3 と同型で格納先が Secrets Manager になるだけ。自動ローテーション機構や
クロスアカウント共有が使える一方、シークレット単価と API コストがかかる。
公開証明書のみで秘密鍵を扱わない本件では Secrets Manager の付加機能は過剰であり、
**Parameter Store (方式 3) で十分**。extraslb 側のクライアント認証 (mTLS) が将来
必要になり秘密鍵も配布する段になったら Secrets Manager へ格上げを検討する。

### 方式 5: S3 から entrypoint で取得

entrypoint 内で `aws s3 cp` (または SDK) により `cacert.crt` を取得して取り込む。

- **長所**: サイズ制限が実質なく、証明書バンドルが大きくても対応可能。バージョニングで履歴管理できる。
  DER (バイナリ) をそのまま置けるため、方式 3 のような Base64 化が不要。
- **短所**: イメージに AWS CLI の同梱が必要 (イメージ肥大)。taskRole への s3:GetObject 付与、
  バケットポリシー、VPC エンドポイント (外部通信不可の subnet の場合) など付帯設定が多い。
  取得失敗時のリトライ・整合性検証 (チェックサム) も自前実装になる。
- **結論**: 証明書サイズが Parameter Store に収まらない場合の代替。それ以外では方式 3 が優位。

### 方式 6: EFS マウント共有

EFS 上に truststore (または `cacert.crt`) を置き、タスク定義の volume でマウントする。

- **長所**: 差し替えが即時 (再起動不要でファイル自体は更新される ※ただし JVM/Elytron は
  起動時読み込みのためプロセス再起動は結局必要)。複数サービスから共有可能。
- **短所**: EFS の可用性・性能・アクセスポイント管理がコンテナ起動の前提条件になり、
  障害点が増える。数 KB のファイル配布に対してインフラが重い。
- **結論**: 既に EFS を他用途でマウントしている場合以外は**非推奨**。

---

## 推奨方針

1. **フェーズ 1 (今回実装)**: 方式 1「ベースイメージ埋め込み + BuildKit Secrets」で開始する。
   - フロント / バックはベースを継承するだけとし、証明書関連の実装をベースに一元化する。
   - CI/CD 上の `cacert.crt` の一次保管場所として Parameter Store を使い、ビルド時に取得して
     `--secret src=` へ渡す構成にしておくと、フェーズ 2 への移行が容易。
2. **フェーズ 2 (ローテーション要件が顕在化したら)**: 方式 3「Parameter Store + ECS secrets
   注入」へ移行する。entrypoint / build-truststore.sh は本実装をそのまま流用でき、
   トラストストア組み立ての実行タイミングをビルド時から起動時に移すだけで済む。
3. どちらのフェーズでも共通の運用事項:
   - **有効期限監視**: 自己署名証明書は期限切れが全断につながる。期限を CloudWatch 等で
     監視し、失効前にローテーションを計画する (例: `keytool -list -v` の出力を定期チェック、
     または Config/Lambda で保管中の `cacert.crt` の NotAfter を監視)。
     ビルド時は `build-truststore.sh` が Owner / Issuer / Valid from をログ出力するので、
     どの証明書が焼き込まれたかは CI のビルドログから追跡できる。
   - **cacerts ベースのトラストストア**: 本実装は JDK cacerts に extraslb 証明書を「追加」した
     トラストストアを使うため、extraslb 以外のパブリック CA 宛通信 (AWS SDK 等) も壊さない。
     `-Djavax.net.ssl.trustStore` を extraslb 証明書単体のストアにしてしまうと
     他の HTTPS 通信が全滅するので注意。
   - **受領するのは CA 証明書 (`cacert.crt`)**: 本実装はこれを前提とする。サーバ証明書
     そのものを直接ピン留めすると、extraslb 側のサーバ証明書再発行のたびにローテーションが
     必要になるため、発行元 (ルート/自己署名 CA) 証明書を信頼登録する。
     受領した `cacert.crt` が本当に CA 証明書かは、ビルドログの Owner / Issuer が一致するか
     (自己署名なら一致)、`keytool -printcert -file cacert.crt` の
     `BasicConstraints: CA:true` で確認できる。
