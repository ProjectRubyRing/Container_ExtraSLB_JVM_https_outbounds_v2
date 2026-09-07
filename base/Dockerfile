# syntax=docker/dockerfile:1.7
#
# ベースコンテナ: JBoss EAP 8.1 + 自己署名 CA 証明書入りトラストストア
#
# ビルド方法 (BuildKit Secrets で証明書を渡す。イメージレイヤーに証明書自体は残らない):
#   DOCKER_BUILDKIT=1 docker build \
#     $(bash scripts/cacert-secret-args.sh) \
#     -t eap81-extraslb-base:1.0 \
#     base/
#
# 入力は各提供元から受領した証明書 (PEM / DER / PKCS#7 のいずれでも可)。
# 提供元ごとに secrets/certs/<name>/ 配下へ置くだけでよく、
# **ファイル名・拡張子は問わない** (cacert.crt / rootCA.pem / ca.cer / 拡張子なし ...)。
# ルート CA / 中間 CA / サーバ証明書のいずれも、また 1 ファイルにチェーンが
# 束ねられていても、build-truststore.sh が中身を見て 1 枚ずつ取り込む。
# certs ディレクトリ配下がまとめて 1 つのシークレット (id=cacerts) として
# 渡されるため、提供元が増えても本 Dockerfile の変更は不要。
#
# EAP 8.1 のランタイムイメージは registry.redhat.io へのログインが必要
# (docker login registry.redhat.io)。JDK バージョンは環境に合わせて変更すること。
ARG EAP_IMAGE=registry.redhat.io/jboss-eap-8/eap81-openjdk17-runtime-openshift-rhel9:latest

FROM ${EAP_IMAGE}

# ------------------------------------------------------------------
# 各種パス・値の定義
#   TRUSTSTORE_PASSWORD はトラストストアの「整合性チェック用」パスワード。
#   トラストストアには秘密鍵を含まず公開証明書のみのため機密情報ではないが、
#   変更したい場合は --build-arg で上書きし、起動時も同じ値を
#   EXTRASLB_TRUSTSTORE_PASSWORD 環境変数で渡すこと。
# ------------------------------------------------------------------
ARG TRUSTSTORE_DIR=/opt/app/security
ARG TRUSTSTORE_FILE=extraslb-truststore.p12
ARG TRUSTSTORE_PASSWORD=changeit

ENV EXTRASLB_TRUSTSTORE_PATH=${TRUSTSTORE_DIR}/${TRUSTSTORE_FILE} \
    EXTRASLB_TRUSTSTORE_PASSWORD=${TRUSTSTORE_PASSWORD} \
    EXTRASLB_TRUSTSTORE_TYPE=PKCS12

USER root

# ビルド用スクリプト・起動スクリプト・JBoss CLI 定義を配置
COPY scripts/build-truststore.sh /usr/local/bin/build-truststore.sh
COPY scripts/entrypoint.sh       /usr/local/bin/entrypoint.sh
COPY jboss-cli/configure-outbound-tls.cli /opt/app/cli/configure-outbound-tls.cli

RUN chmod 0755 /usr/local/bin/build-truststore.sh /usr/local/bin/entrypoint.sh

# ==================================================================
# BuildKit Secrets で全提供元の CA 証明書を **1 つのシークレット
# (id=cacerts)** として受け取り、JDK 標準の cacerts をベースにした
# 1 つのトラストストアへ取り込む。
#   - cacerts をコピー元にするため、パブリック CA 宛の通信も引き続き可能
#   - ファイル名に依存せず、PEM / DER / PKCS#7 の判定と
#     チェーンの分割は build-truststore.sh が中身を見て行う
#   - secret は RUN 実行中のみマウントされ、イメージには truststore のみ残る
#
# 【証明書ソースの追加手順】(例: newsvc を追加する場合)
#   1. ビルドコンテキスト側の secrets/certs/newsvc/ へ証明書を配置する
#      (ファイル名は任意)
#   2. そのままビルドし直す (本 Dockerfile も docker build コマンドも変更不要)
#
#   ※ certs ディレクトリ配下の <name>/ 直下のファイルがそのままソースになり、
#      ディレクトリ名がトラストストア上のエイリアス接頭辞
#      (newsvc-ca-1, newsvc-ca-2, ...) になる。
#   ※ BuildKit のシークレットはディレクトリをマウントできない
#      (moby/buildkit#970) ため、certs ディレクトリは
#      scripts/cacert-secret-args.sh が tar へまとめ、単一シークレットとして
#      渡す。展開とソース列挙は build-truststore.sh 側で行うため、
#      ソースが何個になってもこの RUN 命令は不変。
#   ※ required=true … 証明書を渡し忘れたビルドはここで失敗させる
#      (証明書の入っていないイメージが黙ってできあがるのを防ぐ)。
#   ※ アーカイブの展開に tar を使う。UBI9 ベースの標準イメージには含まれるが、
#      *-minimal 系のイメージへ差し替える場合は tar を導入すること
#      (例: RUN microdnf install -y tar && microdnf clean all)。
#      未導入の場合は build-truststore.sh がその旨を出して停止する。
# ==================================================================
RUN --mount=type=secret,id=cacerts,target=/run/secrets/cacerts.tar,required=true \
    /usr/local/bin/build-truststore.sh \
        /run/secrets/cacerts.tar \
        "${EXTRASLB_TRUSTSTORE_PATH}" \
        "${EXTRASLB_TRUSTSTORE_PASSWORD}" \
    && chown -R 185:0 /opt/app \
    && chmod -R g=u /opt/app \
    && chmod 0444 "${EXTRASLB_TRUSTSTORE_PATH}"

# ==================================================================
# Elytron 設定の「ビルド時適用」と standalone_xml_history の掃除
#
# 【なぜビルド時に適用するのか】
#   起動時に embed-server を実行すると、その 1 回が「1 回目の設定
#   ブートストラップ」になり、続く standalone.sh の本ブートが「2 回目」に
#   なる。2 回目のブートは WildFly Core の
#     ConfigurationFile#createHistoryDirectory()
#   で standalone_xml_history/current を **ディレクトリ rename** して
#   退避しようとするが、この rename だけは configuration ディレクトリの
#   物理的な実体 (overlayfs か / ボリュームか / 所有者は誰か) に依存し、
#   Compose では警告 (WFLYCTL0414) で済むのに ECS では直後の
#   WFLYCTL0082 でブートが異常終了する、という環境差を生む。
#   ビルド時に適用しておけば起動時の embed-server が不要になり
#   (entrypoint.sh の EXTRASLB_TLS_CONFIG_MODE=auto が自動でスキップする)、
#   コンテナ起動あたりの設定ブートストラップが 1 回に戻る。
#   詳細: docs/standalone-xml-history-ecs-vs-compose.md
#
# 【standalone_xml_history を消す理由】
#   イメージ内に standalone_xml_history/current が残っていると、
#   そのディレクトリは overlayfs の「下位レイヤ」になる。下位レイヤの
#   ディレクトリは rename できず (EXDEV)、JDK が mkdir+rmdir に
#   フォールバックして DirectoryNotEmptyException になるため、
#   ボリュームを当てていない Compose 環境で毎回 WFLYCTL0056/0414 が出る。
#   イメージから消しておけば、どちらの環境でも初回ブートは
#   「履歴なし」から始まり rename 自体が発生しない。
#
#   APPLY_TLS_CONFIG_AT_BUILD=false にすると適用をスキップする
#   (JBoss EAP 本体を含まないベースを使う場合など)。その場合でも
#   entrypoint.sh が起動時に適用し、履歴の正規化も行うため安全に動作する。
#
# 【配置順の注意】
#   この RUN は必ず **standalone/log を EFS へのシンボリックリンクに
#   置き換える前** (= base イメージ側) で実行すること。
#   embed-server はブート時に jboss.server.log.dir へ書き込むため、
#   リンク先の EFS がまだ存在しないビルド時にリンク化されていると失敗する。
# ==================================================================
ARG APPLY_TLS_CONFIG_AT_BUILD=true
# 実行ユーザー。ビルド時に root で書き換えた設定ファイルの所有権を戻すために使う
ARG RUN_UID=185
ARG RUN_GID=0

RUN set -eu; \
    CONF_DIR="${JBOSS_HOME:-/opt/server}/standalone/configuration"; \
    CLI_BIN="${JBOSS_HOME:-/opt/server}/bin/jboss-cli.sh"; \
    if [ "${APPLY_TLS_CONFIG_AT_BUILD}" = "true" ] && [ -x "${CLI_BIN}" ] && [ -f "${CONF_DIR}/standalone.xml" ]; then \
        { \
            echo "embed-server --server-config=standalone.xml --std-out=echo"; \
            cat /opt/app/cli/configure-outbound-tls.cli; \
            echo "stop-embedded-server"; \
        } > /tmp/configure-outbound-tls.build.cli; \
        "${CLI_BIN}" --file=/tmp/configure-outbound-tls.build.cli; \
        rm -f /tmp/configure-outbound-tls.build.cli; \
        grep -q 'extraslb-client-ssl-context' "${CONF_DIR}/standalone.xml" \
            || { echo "[base] ERROR: standalone.xml に Elytron 設定が入りませんでした" >&2; exit 1; }; \
        echo "[base] applied Elytron outbound TLS configuration at build time"; \
    else \
        echo "[base] WARN: ビルド時の Elytron 設定適用をスキップしました (起動時に entrypoint.sh が適用します)" >&2; \
    fi; \
    rm -rf "${CONF_DIR}/standalone_xml_history"; \
    if [ -d "${CONF_DIR}" ]; then \
        chown -R "${RUN_UID}:${RUN_GID}" "${CONF_DIR}"; \
        chmod -R g+rwX "${CONF_DIR}"; \
    fi

# EAP イメージ標準の実行ユーザー (jboss / uid=185) に戻す
USER 185

# フロント・バックコンテナは本イメージを FROM に指定し、
# WAR を $JBOSS_HOME/standalone/deployments/ に COPY するだけでよい
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
