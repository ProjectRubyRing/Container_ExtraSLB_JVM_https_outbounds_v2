#!/bin/bash
#
# コンテナ起動時エントリーポイント
#   1. JBoss CLI (embed-server) で Elytron サブシステムに
#      トラストストア / client-ssl-context を設定
#   2. embed-server が作った standalone_xml_history を「安全な形」へ正規化
#      (★ これを行わないと本ブートが異常終了し得る。理由は下記)
#   3. インバウンド HTTPS 用キーストア (application.keystore) の取りこぼしを補完
#      (ベースイメージでビルド時に生成済みなら何もしない。WFLYELY00023 対策)
#   4. JVM システムプロパティ (javax.net.ssl.*) を付与して EAP を起動
#
# トラストストアは extraslb / others など複数ソースの CA 証明書をビルド時に
# 1 ファイルへまとめたもの。証明書ソースが増えても本スクリプトの変更は不要。
#
# ------------------------------------------------------------------
# 【重要】なぜ standalone_xml_history の正規化が必要か
# ------------------------------------------------------------------
# 本スクリプトの embed-server は「1 回目の設定ブートストラップ」である。
# 続く standalone.sh の本ブートは「2 回目」になり、WildFly Core の
# ConfigurationFile#createHistoryDirectory() が
#     standalone_xml_history/current  ->  standalone_xml_history/<timestamp>
# の **ディレクトリ rename** を毎起動必ず実行するようになる。
# この rename は configuration ディレクトリの「物理的な実体」
# (overlayfs か / ボリュームか / 所有者は誰か) に依存する唯一の操作であり、
# Compose と ECS で結果が割れる。失敗すると
#     WFLYCTL0056 (ERROR) Could not rename ...   <- 実際の errno はここに出る
#     WFLYCTL0414 (WARN)  現在の履歴ディレクトリ - .../current の
#                         タイムスタンプ付きバックアップを作成できませんでした
# が出力され、直後の successfulBoot() の copyFile() が同じ原因で失敗すると
#     WFLYCTL0082 Failed to create backup copies of configuration file ...
# となってブートが異常終了する。
# -> 本スクリプトは CLI 実行後に current を空にして rename 自体を発生させない。
#    詳細: docs/standalone-xml-history-ecs-vs-compose.md
#
# 環境変数 (ECS タスク定義 / compose の environment で上書き可能):
#   EXTRASLB_TRUSTSTORE_PATH      トラストストアのパス   (既定: イメージ埋め込み値)
#   EXTRASLB_TRUSTSTORE_PASSWORD  トラストストアのパスワード (既定: changeit)
#   EXTRASLB_TRUSTSTORE_TYPE      トラストストア形式     (既定: PKCS12)
#   SERVER_CONFIG                 サーバ設定ファイル名     (既定: standalone.xml)
#   JBOSS_BIND_ADDRESS            パブリックバインドアドレス (既定: 0.0.0.0)
#   JBOSS_CONF_DIR                configuration ディレクトリ
#                                 (既定: ${JBOSS_HOME}/standalone/configuration)
#   EXTRASLB_TLS_CONFIG_MODE      auto (既定) | always | skip
#                                 auto  = standalone.xml に設定済みなら CLI を実行しない
#                                         (ビルド時適用済みイメージでは 2 回目の
#                                          ブートストラップが完全に消える)
#                                 always= 毎起動必ず CLI を実行する
#                                 skip  = CLI を実行しない
#   EXTRASLB_HISTORY_MODE         rotate (既定) | recreate | purge | off
#                                 rotate  = current の中身を <timestamp> へ退避して空にする
#                                 recreate= rotate に加えて standalone_xml_history を
#                                           必ず作り直す (overlayfs の merged ディレクトリ
#                                           を上位レイヤ専用にして rename を通す)
#                                 purge   = current の中身を退避せず削除する
#                                 off     = 何もしない (従来動作・問題再現用)
#   EXTRASLB_HISTORY_AUTO_RECREATE true (既定) | false
#                                 rename(2) が通らないと実測できた場合にだけ
#                                 履歴ツリーを自動で作り直す
#                                 (readonlyRootFilesystem=false + ボリューム無しの
#                                  構成ではこれが効く。詳細は docs を参照)
#   EXTRASLB_STRICT_PREFLIGHT     true (既定) | false
#                                 false にすると書き込み検証の失敗を警告に留める
#   EXTRASLB_TMP_DIR              CLI 一時ファイルの置き場所 (既定: 自動選択)
#   EXTRASLB_APP_KEYSTORE_MODE    auto (既定) | skip
#                                 auto = サーバ設定が参照するインバウンド HTTPS 用
#                                        キーストア (既定 application.keystore) が
#                                        無ければ EAP と同じ内容で生成し、
#                                        WFLYELY00023 / WFLYELY01084 を出さなくする
#                                        (ベースイメージのビルド時に生成済みなら no-op)
#                                 skip = 何もしない
#                                        (警告は出るが通信への影響は無い。
#                                         docs/wflyely00023-application-keystore.md)
set -euo pipefail

JBOSS_HOME="${JBOSS_HOME:-/opt/server}"
SERVER_CONFIG="${SERVER_CONFIG:-standalone.xml}"
JBOSS_BIND_ADDRESS="${JBOSS_BIND_ADDRESS:-0.0.0.0}"

STANDALONE_DIR="${JBOSS_HOME}/standalone"
# configuration-seed 方式 (別リポジトリの efs-entrypoint.sh) と同じ変数名を使う。
# 併用時はそちらが設定した値をそのまま引き継ぐ。
CONF_DIR="${JBOSS_CONF_DIR:-${STANDALONE_DIR}/configuration}"

EXTRASLB_TRUSTSTORE_PATH="${EXTRASLB_TRUSTSTORE_PATH:-/opt/app/security/extraslb-truststore.p12}"
EXTRASLB_TRUSTSTORE_PASSWORD="${EXTRASLB_TRUSTSTORE_PASSWORD:-changeit}"
EXTRASLB_TRUSTSTORE_TYPE="${EXTRASLB_TRUSTSTORE_TYPE:-PKCS12}"

EXTRASLB_TLS_CONFIG_MODE="${EXTRASLB_TLS_CONFIG_MODE:-auto}"
EXTRASLB_HISTORY_MODE="${EXTRASLB_HISTORY_MODE:-rotate}"
EXTRASLB_HISTORY_AUTO_RECREATE="${EXTRASLB_HISTORY_AUTO_RECREATE:-true}"
EXTRASLB_STRICT_PREFLIGHT="${EXTRASLB_STRICT_PREFLIGHT:-true}"
EXTRASLB_APP_KEYSTORE_MODE="${EXTRASLB_APP_KEYSTORE_MODE:-auto}"

case "${EXTRASLB_HISTORY_MODE}" in
    rotate|recreate|purge|off) ;;
    *) echo "==> [entrypoint] FATAL: EXTRASLB_HISTORY_MODE の値が不正です: '${EXTRASLB_HISTORY_MODE}' (rotate|recreate|purge|off)" >&2; exit 1 ;;
esac

case "${EXTRASLB_APP_KEYSTORE_MODE}" in
    auto|skip) ;;
    *) echo "==> [entrypoint] FATAL: EXTRASLB_APP_KEYSTORE_MODE の値が不正です: '${EXTRASLB_APP_KEYSTORE_MODE}' (auto|skip)" >&2; exit 1 ;;
esac

CLI_SCRIPT="${EXTRASLB_CLI_SCRIPT:-/opt/app/cli/configure-outbound-tls.cli}"
APP_KEYSTORE_SCRIPT="${EXTRASLB_APP_KEYSTORE_SCRIPT:-/usr/local/bin/provision-application-keystore.sh}"

# standalone.xml に設定が入っているかを判定するためのマーカー。
# configure-outbound-tls.cli が必ず追加するリソース名を使う。
TLS_MARKER="${EXTRASLB_TLS_MARKER:-extraslb-client-ssl-context}"

# WildFly は履歴ディレクトリ名を「raw な設定ファイル名」から決める
# (ConfigurationFile: rawName.replace('.', '_') + "_history")。
# standalone サーバでは -c の指定内容に関わらず常に standalone_xml_history。
HISTORY_DIR="${CONF_DIR}/standalone_xml_history"
CURRENT_HISTORY_DIR="${HISTORY_DIR}/current"

# ------------------------------------------------------------------
# 0. 診断ヘルパー
#    ECS では stdout/stderr (awslogs) だけが手掛かりになるため、
#    異常時は必ず「何が・どこで・なぜ」を出してから終了する。
# ------------------------------------------------------------------
say()  { echo "==> [entrypoint] $*"; }
warn() { echo "==> [entrypoint] WARN: $*" >&2; }

dump_diag() {
    {
        echo "---------------- diagnostics ----------------"
        echo "# id";    id    2>/dev/null || true
        echo "# umask"; umask 2>/dev/null || true
        echo "# ls -la ${CONF_DIR}"
        ls -la "${CONF_DIR}" 2>/dev/null || echo "(参照できません)"
        echo "# ls -la ${HISTORY_DIR}"
        ls -la "${HISTORY_DIR}" 2>/dev/null || echo "(存在しません)"
        echo "# mount (standalone / mnt のみ)"
        mount 2>/dev/null | grep -E "standalone|/mnt" || echo "(該当マウント無し)"
        echo "---------------------------------------------"
    } >&2
}

die() {
    echo "==> [entrypoint] FATAL: $*" >&2
    dump_diag
    exit 1
}

# ディレクトリが「本当に書けるか」を実書き込みで判定する。
# mount 情報のパースではなく実書き込みで見ることで、
#   - readonlyRootFilesystem=true によるボリューム未マウント (EROFS)
#   - ボリューム / EFS アクセスポイントの uid,gid 不一致 (EACCES)
# の双方を取りこぼさずに検出できる。
is_writable() {
    local d="$1" probe
    [[ -d "${d}" ]] || return 1
    probe="${d}/.extraslb-writetest.$$"
    if ( : > "${probe}" ) 2>/dev/null; then
        rm -f "${probe}" 2>/dev/null || true
        return 0
    fi
    return 1
}

# 厳格モードでは die、そうでなければ警告のみ
fail_or_warn() {
    if [[ "${EXTRASLB_STRICT_PREFLIGHT}" == "true" ]]; then
        die "$@"
    fi
    warn "$@"
}

# WildFly の履歴ディレクトリ名と同じ書式 (yyyyMMdd-HHmmssSSS)。
# この書式にしておくと WildFly 側の 30 日クリーンアップ
# (TIMESTAMP_PATTERN = 8 桁 + '-' + 9 桁) の対象にもなり、退避物が溜まり続けない。
history_timestamp() {
    local ts
    ts="$(date +%Y%m%d-%H%M%S%3N 2>/dev/null || true)"
    # GNU date 以外で %3N が展開されない環境向けフォールバック
    if [[ ! "${ts}" =~ ^[0-9]{8}-[0-9]{9}$ ]]; then
        ts="$(date +%Y%m%d-%H%M%S)000"
    fi
    printf '%s' "${ts}"
}

say "JBOSS_HOME=${JBOSS_HOME}, SERVER_CONFIG=${SERVER_CONFIG}"
say "configuration=${CONF_DIR}"
say "truststore=${EXTRASLB_TRUSTSTORE_PATH}"

# ------------------------------------------------------------------
# 1. 事前検証 (JBoss へ制御を渡す前にすべて潰す)
# ------------------------------------------------------------------
if [[ ! -r "${EXTRASLB_TRUSTSTORE_PATH}" ]]; then
    die "truststore が読めません: ${EXTRASLB_TRUSTSTORE_PATH}"
fi

[[ -d "${CONF_DIR}" ]] || die "configuration ディレクトリがありません: ${CONF_DIR}"

if [[ ! -f "${CONF_DIR}/${SERVER_CONFIG}" ]]; then
    echo "==> [entrypoint] configuration-seed 方式と併用している場合、seed の" >&2
    echo "==> [entrypoint] 書き戻し (efs-entrypoint.sh の '1. configuration の復元')" >&2
    echo "==> [entrypoint] より **後** に本スクリプトが動く必要があります。" >&2
    echo "==> [entrypoint] 推奨: ENTRYPOINT=efs-entrypoint.sh / CMD=entrypoint.sh" >&2
    die "${CONF_DIR}/${SERVER_CONFIG} がありません。"
fi

# configuration そのものが書けなければ、この先はすべて無駄。
# ECS (readonlyRootFilesystem=true + ボリューム未マウント) はここで止まる。
if ! is_writable "${CONF_DIR}"; then
    echo "==> [entrypoint] 考えられる原因:" >&2
    echo "==> [entrypoint]   (a) readonlyRootFilesystem=true なのに ${CONF_DIR} へ" >&2
    echo "==> [entrypoint]       書き込み可能ボリュームを当てていない (EROFS)" >&2
    echo "==> [entrypoint]   (b) ボリューム / EFS アクセスポイントの uid,gid と" >&2
    echo "==> [entrypoint]       実行ユーザーの不一致 (EACCES)" >&2
    fail_or_warn "${CONF_DIR} に書き込めません。"
fi

# ------------------------------------------------------------------
# 2. 履歴ディレクトリを「実行ユーザー所有」で先に作っておく
#
#    ★ ECS 側の異常終了 (WFLYCTL0082) に直結する対策。
#    standalone_xml_history を JBoss に作らせず、ここで作ることで
#      - 所有者が必ず実行ユーザーになる (後続の rename / unlink が EACCES にならない)
#      - 書き込み可否をこの時点で実書き込み検証できる
#    ようにする。WildFly の ConfigurationFile#mkdir は
#    「存在すれば何もしない」ため、先に作ってあっても副作用は無い。
# ------------------------------------------------------------------
mkdir -p "${HISTORY_DIR}/snapshot" "${CURRENT_HISTORY_DIR}" 2>/dev/null || true
chmod g+rwX "${HISTORY_DIR}" "${HISTORY_DIR}/snapshot" "${CURRENT_HISTORY_DIR}" 2>/dev/null || true

# configuration がボリューム (bind mount) なのか、イメージの overlayfs なのかを
# 起動ログに残す。この 1 行があるだけで
#   「ボリュームを当てているつもりが当たっていない」
#   「overlayfs 上なので履歴ディレクトリの rename が原理的に通らない」
# の切り分けが即座にできる。
if grep -qs -- " ${CONF_DIR} " /proc/self/mounts 2>/dev/null; then
    say "configuration はマウントされたボリュームです ($(awk -v d="${CONF_DIR}" '$2==d{print $3; exit}' /proc/self/mounts 2>/dev/null))"
else
    say "configuration はマウントされていません (イメージの overlayfs 上で動作)"
fi

if [[ ! -d "${HISTORY_DIR}" ]]; then
    fail_or_warn "${HISTORY_DIR} を作成できません。${CONF_DIR} の所有者・権限・マウント状態を確認してください。"
elif ! is_writable "${HISTORY_DIR}"; then
    echo "==> [entrypoint] JBoss EAP はブート完了時に" >&2
    echo "==> [entrypoint]   ${HISTORY_DIR}/${SERVER_CONFIG%.xml}.{initial,boot,last}.xml" >&2
    echo "==> [entrypoint] を書き込みます。ここが書けないと" >&2
    echo "==> [entrypoint]   WFLYCTL0082 Failed to create backup copies of configuration file" >&2
    echo "==> [entrypoint] でブートが異常終了します (直前に WFLYCTL0056 / WFLYCTL0414 が出ます)。" >&2
    fail_or_warn "${HISTORY_DIR} に書き込めません。"
fi

# ------------------------------------------------------------------
# 3. JBoss CLI (組み込みサーバ) で Elytron を設定
#    - embed-server のヘッダはシェル変数展開で組み立て、SERVER_CONFIG を
#      確実に反映させる。
#    - CLI スクリプト側は if/end-if で冪等化済み。コンテナ再起動時に
#      設定済みの standalone.xml が残っていても安全に再実行できる。
#    - ${env.*} 式は CLI では解決されず standalone.xml に式のまま保存され、
#      サーバ起動時に環境変数から解決される。
# ------------------------------------------------------------------
need_cli=true
case "${EXTRASLB_TLS_CONFIG_MODE}" in
    skip)
        need_cli=false
        say "EXTRASLB_TLS_CONFIG_MODE=skip のため JBoss CLI を実行しません"
        ;;
    always)
        need_cli=true
        ;;
    auto)
        if grep -q -- "${TLS_MARKER}" "${CONF_DIR}/${SERVER_CONFIG}" 2>/dev/null; then
            need_cli=false
            say "${SERVER_CONFIG} に ${TLS_MARKER} が既に存在するため JBoss CLI をスキップします"
            say "(2 回目の設定ブートストラップが発生しないため履歴ローテーションも起きません)"
        fi
        ;;
    *)
        die "EXTRASLB_TLS_CONFIG_MODE の値が不正です: '${EXTRASLB_TLS_CONFIG_MODE}' (auto|always|skip)"
        ;;
esac

if [[ "${need_cli}" == "true" ]]; then
    [[ -r "${CLI_SCRIPT}" ]] || die "CLI スクリプトが読めません: ${CLI_SCRIPT}"

    # 一時ファイルの置き場所。
    # ★ readonlyRootFilesystem=true では /tmp が EROFS になり、従来の
    #   `mktemp /tmp/...` は set -e でその場で死んでいた (ECS 固有の無音死)。
    #   書ける場所を順に探し、どこにも書けない場合は理由を出して落とす。
    CLI_TMP_DIR=""
    for d in "${EXTRASLB_TMP_DIR:-}" "${TMPDIR:-}" "${STANDALONE_DIR}/tmp" "${CONF_DIR}" /tmp; do
        [[ -n "${d}" ]] || continue
        if is_writable "${d}"; then CLI_TMP_DIR="${d}"; break; fi
    done
    [[ -n "${CLI_TMP_DIR}" ]] \
        || die "CLI 一時ファイルを置ける書き込み可能ディレクトリがありません (EXTRASLB_TMP_DIR で明示指定してください)"

    RUNTIME_CLI="$(mktemp "${CLI_TMP_DIR}/configure-outbound-tls.XXXXXX.cli")" \
        || die "CLI 一時ファイルを作成できません (${CLI_TMP_DIR})"
    trap 'rm -f "${RUNTIME_CLI}" 2>/dev/null || true' EXIT

    {
        echo "embed-server --server-config=${SERVER_CONFIG} --std-out=echo"
        cat "${CLI_SCRIPT}"
        echo "stop-embedded-server"
    } > "${RUNTIME_CLI}"

    say "Applying Elytron outbound TLS configuration via JBoss CLI (tmp=${CLI_TMP_DIR})"
    if ! "${JBOSS_HOME}/bin/jboss-cli.sh" --file="${RUNTIME_CLI}"; then
        echo "==> [entrypoint] embed-server による設定適用に失敗しました。" >&2
        echo "==> [entrypoint] 直前の CLI 出力に WFLYCTL0056 / WFLYCTL0082 がある場合は" >&2
        echo "==> [entrypoint] ${CONF_DIR} 配下の書き込み権限 (所有者・マウント) を確認してください。" >&2
        die "jboss-cli.sh --file=${RUNTIME_CLI} が異常終了しました。"
    fi
    rm -f "${RUNTIME_CLI}" 2>/dev/null || true
    trap - EXIT
    say "JBoss CLI configuration completed"
fi

# ------------------------------------------------------------------
# 4. ★ 本修正の中核: standalone_xml_history/current を空にする
#
#    embed-server は「1 回のブート」として standalone_xml_history/current に
#    standalone.vN.xml を残す。この状態で standalone.sh を起動すると
#    WildFly Core は current をディレクトリ rename で退避しようとする:
#
#      ConfigurationFile#createHistoryDirectory()
#        Files.move(.../current, .../<yyyyMMdd-HHmmssSSS>, REPLACE_EXISTING)
#
#    ディレクトリ rename は configuration の実体に強く依存する:
#      - overlayfs の下位レイヤ由来のディレクトリ -> EXDEV
#        -> JDK が mkdir + rmdir にフォールバックし DirectoryNotEmptyException
#        -> WFLYCTL0056/0414 は出るが「親ディレクトリは書ける」ので後続は成功
#        -> **Compose は警告だけ出して起動してしまう**
#      - 親ディレクトリに書けない (EACCES) / read-only (EROFS)
#        -> rename も失敗し、直後の successfulBoot() の copyFile() も失敗
#        -> WFLYCTL0082 -> **ECS は異常終了する**
#
#    current が空 (listFiles().length == 0) なら WildFly は rename を
#    一切実行しない。ここで空にしておけば、どのファイルシステム・どの
#    マウント形態でも「起動時の履歴ローテーション」が失敗しなくなる。
#
#    rotate  : current の中身を <timestamp> へ退避してから空にする
#              (rename ではなく cp + rm で行うためレイヤ跨ぎでも成功する)
#    recreate: rotate に加えて standalone_xml_history 自体を必ず作り直す
#    purge   : 退避せずに削除する
#    off     : 何もしない (従来動作。問題の再現用)
#
#    さらに 4-2 / 4-3 で「そもそも rename(2) が通るディレクトリなのか」を
#    実測し、通らない場合は履歴ツリーを作り直して恒久的に通るようにする。
#    (readonlyRootFilesystem=false + ボリューム無しの構成で必須。理由は 4-2)
# ------------------------------------------------------------------
normalize_history() {
    local ts backup

    [[ -d "${CURRENT_HISTORY_DIR}" ]] || return 0

    # 空なら WildFly は rename しないので何もしなくてよい
    if [[ -z "$(ls -A "${CURRENT_HISTORY_DIR}" 2>/dev/null)" ]]; then
        say "standalone_xml_history/current は空です (履歴ローテーションは発生しません)"
        return 0
    fi

    if [[ "${EXTRASLB_HISTORY_MODE}" == "rotate" || "${EXTRASLB_HISTORY_MODE}" == "recreate" ]]; then
        ts="$(history_timestamp)"
        backup="${HISTORY_DIR}/${ts}"
        if mkdir -p "${backup}" 2>/dev/null \
           && cp -R "${CURRENT_HISTORY_DIR}/." "${backup}/" 2>/dev/null; then
            say "standalone_xml_history/current を ${ts} へ退避しました"
        else
            warn "current の退避に失敗したため、退避せずに空にします (${backup})"
            rm -rf "${backup}" 2>/dev/null || true
        fi
    fi

    # 中身だけを消す。current ディレクトリ自体は残す
    # (WildFly の mkdir は「存在すれば再利用」なので所有者を保てる)
    if ! find "${CURRENT_HISTORY_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
        fail_or_warn "${CURRENT_HISTORY_DIR} の中身を削除できません。所有者と権限を確認してください。"
        return 0
    fi
    say "standalone_xml_history/current を空にしました (mode=${EXTRASLB_HISTORY_MODE})"
}

# ------------------------------------------------------------------
# 4-2. rename(2) が通るディレクトリかを「実測」する
#
#    ★ readonlyRootFilesystem=false + ボリューム無し (= configuration が
#      イメージの overlayfs のまま) の構成では、これが決定的に効く。
#
#    overlayfs は「下位レイヤを持つディレクトリ (merged ディレクトリ)」の
#    rename を原理的に拒否し EXDEV を返す (redirect_dir=off が既定)。
#    イメージビルド時に一度でもサーバ / CLI を起動していると
#    configuration/standalone_xml_history/current がイメージに焼き込まれ、
#    そのディレクトリは **何度上書きしても merged のまま**なので、
#    ファイルの所有者や権限が完全に正しくても rename は永遠に失敗する。
#    -> :reload のたびに WFLYCTL0056/0414 が出続ける。
#
#    判定方法: mv は EXDEV のとき「コピー + 削除」へフォールバックして
#    成功してしまうため、mv の成否では判定できない。
#    そこで **mv の前後で inode 番号が保たれたか**で rename(2) の成否を見る。
#      inode が同じ -> rename(2) が成功した (renameable)
#      inode が違う -> フォールバックした = rename(2) は失敗する
#    current は 4-1 で空にしてあるので、フォールバックしても副作用は無い。
# ------------------------------------------------------------------
history_rename_probe() {
    local probe before after

    command -v stat >/dev/null 2>&1 || return 2   # 判定不能
    [[ -d "${CURRENT_HISTORY_DIR}" ]] || return 2

    probe="${HISTORY_DIR}/.rename-probe.$$"
    rm -rf "${probe}" 2>/dev/null || true

    before="$(stat -c %i "${CURRENT_HISTORY_DIR}" 2>/dev/null || true)"
    [[ -n "${before}" ]] || return 2

    mv "${CURRENT_HISTORY_DIR}" "${probe}" 2>/dev/null || return 1
    after="$(stat -c %i "${probe}" 2>/dev/null || true)"

    # 元に戻す (戻せなくても current は作り直せばよい)
    mv "${probe}" "${CURRENT_HISTORY_DIR}" 2>/dev/null || true
    rm -rf "${probe}" 2>/dev/null || true
    mkdir -p "${CURRENT_HISTORY_DIR}" 2>/dev/null || true

    [[ -n "${after}" && "${before}" == "${after}" ]]
}

# ------------------------------------------------------------------
# 4-3. 履歴ツリーを「rename できる形」に作り直す
#
#    overlayfs 上で merged ディレクトリを rename 可能にする唯一の方法は、
#    いったん削除してから作り直すこと。削除で whiteout が作られ、
#    作り直したディレクトリは opaque な上位レイヤ専用ディレクトリになる
#    (= 下位レイヤを持たない) ため、以後 rename(2) が通るようになる。
#
#    中身 (standalone.initial.xml / <timestamp>/ など) は退避して戻すので
#    履歴は失われない。
# ------------------------------------------------------------------
recreate_history() {
    local staging="${CONF_DIR}/.standalone_xml_history.rebuild.$$"

    rm -rf "${staging}" 2>/dev/null || true
    mkdir -p "${staging}" 2>/dev/null \
        || { warn "履歴ツリーの作り直し用ディレクトリを作成できません (${staging})"; return 1; }

    cp -R "${HISTORY_DIR}/." "${staging}/" 2>/dev/null || true
    if ! rm -rf "${HISTORY_DIR}" 2>/dev/null; then
        warn "${HISTORY_DIR} を削除できないため作り直しを中止します"
        rm -rf "${staging}" 2>/dev/null || true
        return 1
    fi
    if ! mkdir -p "${HISTORY_DIR}" 2>/dev/null; then
        warn "${HISTORY_DIR} を再作成できません"
        # 退避したものを戻せるだけ戻す
        mkdir -p "${HISTORY_DIR}" 2>/dev/null || true
        cp -R "${staging}/." "${HISTORY_DIR}/" 2>/dev/null || true
        rm -rf "${staging}" 2>/dev/null || true
        return 1
    fi
    cp -R "${staging}/." "${HISTORY_DIR}/" 2>/dev/null || true
    rm -rf "${staging}" 2>/dev/null || true
    mkdir -p "${HISTORY_DIR}/snapshot" "${CURRENT_HISTORY_DIR}" 2>/dev/null || true
    chmod g+rwX "${HISTORY_DIR}" "${HISTORY_DIR}/snapshot" "${CURRENT_HISTORY_DIR}" 2>/dev/null || true
    return 0
}

if [[ "${EXTRASLB_HISTORY_MODE}" == "off" ]]; then
    warn "EXTRASLB_HISTORY_MODE=off: 履歴ローテーションを JBoss に任せます (WFLYCTL0414/0082 のリスクあり)"
else
    normalize_history

    if [[ "${EXTRASLB_HISTORY_MODE}" == "recreate" ]]; then
        if recreate_history; then
            say "standalone_xml_history を作り直しました (mode=recreate)"
        else
            fail_or_warn "standalone_xml_history を作り直せませんでした。"
        fi
    elif [[ "${EXTRASLB_HISTORY_AUTO_RECREATE}" == "true" ]]; then
        if history_rename_probe; then
            say "履歴ディレクトリの rename 検査: OK (JBoss 側のローテーションも成功します)"
        else
            rc=$?
            if [[ "${rc}" -eq 2 ]]; then
                warn "履歴ディレクトリの rename 検査を実施できませんでした (stat 不在等)"
            else
                say "履歴ディレクトリの rename 検査: NG"
                say "  -> ${HISTORY_DIR} は overlayfs の下位レイヤを持つ merged ディレクトリです。"
                say "  -> このままでは :reload 等のたびに WFLYCTL0056/0414 が出続けるため作り直します。"
                if recreate_history; then
                    say "standalone_xml_history を上位レイヤ専用ディレクトリとして作り直しました"
                else
                    warn "作り直しに失敗しました。current は空にしてあるため起動自体は継続します。"
                fi
            fi
        fi
    fi
fi

# ------------------------------------------------------------------
# 5. インバウンド (サーバ側) HTTPS 用キーストアの補完
#
#    【対象の警告】
#      WARN [org.wildfly.extension.elytron] WFLYELY00023:
#           KeyStore file '.../configuration/application.keystore'
#           does not exist. Used blank.
#      WARN [org.wildfly.extension.elytron] WFLYELY01084:
#           KeyStore ... not found, it will be auto-generated on first use ...
#
#    本プロジェクトが設定するアウトバウンド TLS (extraslb-trust-store /
#    extraslb-client-ssl-context / default-ssl-context) とは **無関係**で、
#    EAP 標準設定の applicationKS (インバウンド 8443 用のサーバ鍵ストア) が
#    出している。実体ファイルは同梱されず初回 HTTPS 接続時に遅延生成される
#    一方、Elytron の key-store サービスは誰も参照していなくてもブートごとに
#    ACTIVE で起動するため、ファイルが無い間は毎起動出続ける。
#    通信影響が無いことの検証記録:
#      docs/wflyely00023-application-keystore.md
#
#    【ここで行うこと】
#    ベースイメージのビルド時 (base/Dockerfile の
#    PROVISION_APPLICATION_KEYSTORE) に生成済みであれば何もしない。
#    次のような「イメージの configuration がそのまま使われない」ケースで
#    取りこぼしを補完するためにここでも呼ぶ:
#      - configuration-seed 方式や外部ボリュームで configuration を差し替えた
#      - SERVER_CONFIG にビルド時と異なる設定ファイルを指定した
#      - APPLY_TLS_CONFIG_AT_BUILD=false で作ったベースを使っている
#
#    ★ この呼び出しは EAP 起動より前でなければ意味が無い。
#      警告はブート中の key-store サービス起動時に出るため、
#      その時点でファイルが存在している必要がある。
#    ★ 失敗しても起動は止めない (元々「警告が出るだけ」の事象であり、
#      対処の失敗がそれより重い障害になっては本末転倒なため)。
# ------------------------------------------------------------------
if [[ "${EXTRASLB_APP_KEYSTORE_MODE}" == "skip" ]]; then
    say "EXTRASLB_APP_KEYSTORE_MODE=skip: インバウンド HTTPS 用キーストアの補完を行いません"
elif [[ -x "${APP_KEYSTORE_SCRIPT}" ]]; then
    "${APP_KEYSTORE_SCRIPT}" "${CONF_DIR}/${SERVER_CONFIG}" || \
        warn "インバウンド HTTPS 用キーストアの補完に失敗しました (WFLYELY00023 が出ますが通信影響はありません)"
else
    warn "${APP_KEYSTORE_SCRIPT} が実行できないため、インバウンド HTTPS 用キーストアの補完をスキップします"
fi

# ------------------------------------------------------------------
# 6. EAP 起動
#    javax.net.ssl.* は standalone.sh のサーバ引数として渡すと
#    サーバプロセスのシステムプロパティとして起動初期に設定される。
#    (JAVA_OPTS を直接上書きしないため、イメージ既定のメモリ設定等を壊さない)
#    HttpsURLConnection や、システムプロパティからトラストストアを解決する
#    HTTP クライアントライブラリはこちらで取り込んだ証明書を信頼する。
# ------------------------------------------------------------------
say "preflight OK. starting JBoss EAP"
exec "${JBOSS_HOME}/bin/standalone.sh" \
    -b "${JBOSS_BIND_ADDRESS}" \
    -c "${SERVER_CONFIG}" \
    -Djavax.net.ssl.trustStore="${EXTRASLB_TRUSTSTORE_PATH}" \
    -Djavax.net.ssl.trustStorePassword="${EXTRASLB_TRUSTSTORE_PASSWORD}" \
    -Djavax.net.ssl.trustStoreType="${EXTRASLB_TRUSTSTORE_TYPE}" \
    "$@"
