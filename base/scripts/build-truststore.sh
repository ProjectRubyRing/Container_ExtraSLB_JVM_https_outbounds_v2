#!/bin/bash
#
# build-truststore.sh <cacert-archive|cacert-dir|cacert-file> <output-p12> <store-password> [source-name]
#
# コンテナビルド時に実行し、受領した CA 証明書 (cacert.crt) を
# JDK 標準 cacerts のコピーへ追加した PKCS12 トラストストアを生成する。
# 複数の提供元 (extraslb / others / ...) の証明書をまとめて 1 つの
# トラストストアへ取り込める。
#
# 第 1 引数の扱い (拡張子ではなく中身を見て自動判別する):
#   tar アーカイブ … 展開してディレクトリとして扱う (下記レイアウト (a))。
#                    BuildKit Secrets はディレクトリをマウントできない
#                    (moby/buildkit#970) ため、certs ディレクトリ全体を
#                    1 つの tar にまとめ、単一の --secret id=cacerts で
#                    受け取るビルド時取り込み方式はこれを使う。
#                    → ソースが増えても Dockerfile の変更は不要。
#   ディレクトリ   … 次の 2 レイアウトを受け付ける (混在も可)。
#                    (a) <dir>/<name>/<any>.crt … サブディレクトリ名がソース名
#                          certs/extraslb/cacert.crt -> extraslb-ca-1, extraslb-ca-2, ...
#                          certs/others/cacert.crt   -> others-ca-1, ...
#                        1 ソースに複数ファイルを置いた場合もエイリアスは
#                        そのソース内で連番が継続する (extraslb-ca-3, ...)。
#                    (b) <dir>/<name>.crt        … ファイル名 (拡張子を除く) がソース名
#                        起動時取り込み方式 (docs/certificate-management-strategies.md
#                        方式 3) が生成するレイアウト。
#   ファイル       … そのファイル 1 つだけを取り込む。ソース名は第 4 引数
#                    (既定: extraslb)。
#
# 共通の前提:
#   - cacert.crt は PEM (Base64 テキスト) / DER (バイナリ) のどちらでもよい。
#     拡張子ではなくファイルの中身から形式を自動判別する。
#   - PEM で複数証明書 (チェーン) が連結されていても全て取り込む
#   - cacerts ベースのため、パブリック CA 宛の HTTPS 通信も引き続き成功する
set -euo pipefail

CRT_INPUT="${1:?usage: build-truststore.sh <cacert-archive|cacert-dir|cacert-file> <output-p12> <store-password> [source-name]}"
OUT_STORE="${2:?output truststore path is required}"
STORE_PASS="${3:?truststore password is required}"
FALLBACK_SRC_NAME="${4:-extraslb}"

CACERTS="${JAVA_HOME:?JAVA_HOME is not set}/lib/security/cacerts"
CACERTS_PASS="changeit"   # JDK 標準 cacerts の既定パスワード

# keytool 共通オプション。
#   -J-Djava.security.egd=file:/dev/./urandom
#     コンテナ内はエントロピーが乏しく、PKCS12 書き出し時の乱数生成
#     (salt / IV) が /dev/random 待ちでブロックしてビルドが停止することがある。
#     非ブロッキングな /dev/urandom を明示して回避する。
#     ("/dev/./urandom" と書くのは JDK 側の既知の読み替え対策。)
KEYTOOL_OPTS=(-J-Djava.security.egd=file:/dev/./urandom)

# keytool が万一入力待ちに入ってもビルドを無限に待たせないための上限 (秒)。
KEYTOOL_TIMEOUT="${KEYTOOL_TIMEOUT:-300}"

# アーカイブ展開・PEM 分割用の作業ディレクトリ (終了時に必ず削除する)。
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# ソース名 (= エイリアス接頭辞) に使える文字へ正規化する。
# keytool のエイリアスは大文字小文字を区別しないため小文字へ寄せる。
sanitize_name() {
    printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9._-' '-'
}

# tar アーカイブかどうかをマジックナンバーで判定する。
# tar ヘッダは offset 257 から "ustar" で始まる (POSIX / GNU 形式とも共通)。
# 証明書 (PEM テキスト / DER バイナリ) がここに一致することはない。
is_tar_archive() {
    [[ -f "$1" && -s "$1" ]] || return 1
    [[ "$(LC_ALL=C dd if="$1" bs=1 skip=257 count=5 2>/dev/null)" == "ustar" ]]
}

# ------------------------------------------------------------------
# 取り込み対象ソースの列挙
#   CRT_FILES  : 実ファイルパス
#   SRC_NAMES  : ソース名 (エイリアス接頭辞)
#   SRC_LABELS : ログ表示用の名前 (作業ディレクトリの実パスは出さない)
# ------------------------------------------------------------------
CRT_FILES=()
SRC_NAMES=()
SRC_LABELS=()

add_source() {
    local NAME="$1" FILE="$2" LABEL="$3"
    CRT_FILES+=("${FILE}")
    SRC_NAMES+=("${NAME}")
    SRC_LABELS+=("${LABEL}")
    echo "    - ${LABEL}: source name '${NAME}' (alias prefix '${NAME}-ca-')"
}

# --- tar で渡された場合はここでディレクトリへ展開する ---------------
if is_tar_archive "${CRT_INPUT}"; then
    echo "==> Detected tar archive: ${CRT_INPUT}"
    if ! command -v tar >/dev/null 2>&1; then
        echo "ERROR: tar command not found in the build image" >&2
        echo "       証明書アーカイブの展開に tar が必要です。" >&2
        echo "       ベースイメージへ tar を導入するか、証明書を" >&2
        echo "       ディレクトリのまま渡す方式へ切り替えること。" >&2
        exit 1
    fi
    EXTRACT_DIR="${WORK_DIR}/extracted"
    mkdir -p "${EXTRACT_DIR}"
    if ! tar -xf "${CRT_INPUT}" -C "${EXTRACT_DIR}"; then
        echo "ERROR: failed to extract certificate archive: ${CRT_INPUT}" >&2
        echo "       scripts/cacert-secret-args.sh が生成した tar を" >&2
        echo "       --secret id=cacerts,src=<bundle>.tar で渡しているか確認すること。" >&2
        exit 1
    fi
    CRT_INPUT="${EXTRACT_DIR}"
fi

if [[ -d "${CRT_INPUT}" ]]; then
    echo "==> Scanning certificate sources under ${CRT_INPUT}"
    for ENTRY in "${CRT_INPUT}"/*; do
        [[ -e "${ENTRY}" ]] || continue
        BASE="$(basename "${ENTRY}")"

        if [[ -d "${ENTRY}" ]]; then
            # レイアウト (a): <dir>/<name>/*.crt — ディレクトリ名がソース名
            NAME="$(sanitize_name "${BASE}")"
            FOUND_IN_DIR=0
            for F in "${ENTRY}"/*; do
                [[ -f "${F}" ]] || continue
                if [[ ! -s "${F}" ]]; then
                    echo "    - ${BASE}/$(basename "${F}"): skipped (empty file)"
                    continue
                fi
                add_source "${NAME}" "${F}" "${BASE}/$(basename "${F}")"
                FOUND_IN_DIR=$((FOUND_IN_DIR + 1))
            done
            if [[ "${FOUND_IN_DIR}" -eq 0 ]]; then
                echo "    - ${BASE}/: skipped (no certificate file in this source directory)"
            fi
        elif [[ -f "${ENTRY}" ]]; then
            # レイアウト (b): <dir>/<name>.crt — ファイル名がソース名
            #
            # BuildKit の required=false なシークレットは、--secret が指定されな
            # かった場合に空ファイルとしてマウントされることがある。実際には
            # 渡していないソースはここで読み飛ばす。
            if [[ ! -s "${ENTRY}" ]]; then
                echo "    - ${BASE}: skipped (empty file)"
                continue
            fi
            add_source "$(sanitize_name "${BASE%.*}")" "${ENTRY}" "${BASE}"
        fi
    done
elif [[ -s "${CRT_INPUT}" ]]; then
    add_source "$(sanitize_name "${FALLBACK_SRC_NAME}")" "${CRT_INPUT}" "${CRT_INPUT}"
else
    echo "ERROR: certificate input not found or empty: ${CRT_INPUT}" >&2
    exit 1
fi

if [[ "${#CRT_FILES[@]}" -eq 0 ]]; then
    echo "ERROR: no certificate source found in: ${CRT_INPUT}" >&2
    echo "       確認事項:" >&2
    echo "         - docker build に証明書アーカイブを渡したか" >&2
    echo "             --secret id=cacerts,src=secrets/cacerts-bundle.tar" >&2
    echo "           (bash scripts/cacert-secret-args.sh がアーカイブごと生成する)" >&2
    echo "         - アーカイブに <name>/cacert.crt が含まれているか" >&2
    echo "             tar -tf secrets/cacerts-bundle.tar" >&2
    exit 1
fi

mkdir -p "$(dirname "${OUT_STORE}")"

# ------------------------------------------------------------------
# ビルドが止まったときに切り分けできるよう、前提を先にログへ出す。
#   UBI9 + dnf install java-21-openjdk の構成では cacerts は JDK 同梱では
#   なく /etc/pki/ca-trust/extracted/java/cacerts へのシンボリックリンク
#   (update-ca-trust 管理) になっている点に注意。
# ------------------------------------------------------------------
echo "==> JAVA_HOME=${JAVA_HOME}"
echo "==> keytool: $(command -v keytool || echo 'NOT FOUND')"
"${JAVA_HOME}/bin/java" -version </dev/null 2>&1 || true
echo "==> Source cacerts: ${CACERTS} -> $(readlink -f "${CACERTS}" 2>/dev/null || echo '(unresolved)')"
if [[ ! -s "${CACERTS}" ]]; then
    echo "ERROR: JDK cacerts not found or empty: ${CACERTS}" >&2
    echo "       (UBI では ca-certificates 未導入 / update-ca-trust 未実行の可能性)" >&2
    exit 1
fi
ls -lL "${CACERTS}"

# cacerts 自体の形式も中身から判定する。
#   JDK 同梱・RHEL の update-ca-trust 生成物はいずれも JKS (magic feedfeed) だが、
#   将来 PKCS12 に変わっても動くようにマジックナンバーで見分ける。
if [[ "$(od -An -tx1 -N4 "${CACERTS}" | tr -d ' \n')" == "feedfeed" ]]; then
    CACERTS_TYPE=JKS
else
    CACERTS_TYPE=PKCS12
fi
echo "==> Source cacerts type: ${CACERTS_TYPE}"

# ------------------------------------------------------------------
# cacerts (JKS) を PKCS12 へ変換したコピーを作る。
#   keytool -importkeystore は進捗・完了メッセージ・SHA-1 警告を
#   *stdout ではなく stderr* に出すため ">/dev/null" では抑止できない。
#   出力は変数へ退避し、失敗したときだけ表示する。
#   併せてビルドが無言で停止しないよう以下を行う:
#     - </dev/null : パスワード等の入力待ちに入らせない
#     - timeout    : 停止しても上限で打ち切り、原因の当たりを出して落とす
# ------------------------------------------------------------------
echo "==> Creating truststore from JDK cacerts: ${OUT_STORE}"
IMPORT_LOG=""
IMPORT_RC=0
IMPORT_LOG="$(timeout "${KEYTOOL_TIMEOUT}" \
    keytool "${KEYTOOL_OPTS[@]}" -J-Duser.language=en -J-Duser.country=US \
        -importkeystore \
        -srckeystore  "${CACERTS}"  -srcstoretype "${CACERTS_TYPE}" -srcstorepass "${CACERTS_PASS}" \
        -destkeystore "${OUT_STORE}" -deststoretype PKCS12 \
        -deststorepass "${STORE_PASS}" \
        -noprompt </dev/null 2>&1)" || IMPORT_RC=$?

if [[ "${IMPORT_RC}" -eq 124 ]]; then
    echo "ERROR: keytool -importkeystore timed out after ${KEYTOOL_TIMEOUT}s" >&2
    echo "       確認事項:" >&2
    echo "         - コンテナ内のエントロピー枯渇 (/dev/random 待ち)" >&2
    echo "         - ${CACERTS} がネットワーク/壊れたマウント上にないか" >&2
    echo "       KEYTOOL_TIMEOUT 環境変数で上限を延長できる。" >&2
    exit 1
elif [[ "${IMPORT_RC}" -ne 0 ]]; then
    echo "${IMPORT_LOG}" >&2
    echo "ERROR: failed to convert ${CACERTS} into ${OUT_STORE} (exit ${IMPORT_RC})" >&2
    exit 1
fi
echo "==> $(LC_ALL=C grep -c '^Entry for alias' <<<"${IMPORT_LOG}" || true) entrie(s) copied from cacerts"

# ------------------------------------------------------------------
# ソースごとに証明書を取り込む
#   SRC_SEQ はソース単位のエイリアス連番。1 ソースが複数ファイルに
#   分かれていても extraslb-ca-1, extraslb-ca-2, ... と続けて振る。
# ------------------------------------------------------------------
TOTAL_FOUND=0
TOTAL_IMPORTED=0
SUMMARY=()
declare -A SRC_SEQ=()

for IDX in "${!CRT_FILES[@]}"; do
    CRT_FILE="${CRT_FILES[${IDX}]}"
    SRC_NAME="${SRC_NAMES[${IDX}]}"
    SRC_LABEL="${SRC_LABELS[${IDX}]}"
    SPLIT_DIR="${WORK_DIR}/split/${IDX}"
    mkdir -p "${SPLIT_DIR}"

    echo "------------------------------------------------------------------"
    echo "==> Source '${SRC_NAME}': ${SRC_LABEL}"

    # --------------------------------------------------------------
    # 入力形式の判別
    #   .crt は PEM / DER いずれの可能性もあるため、BEGIN CERTIFICATE 行の
    #   有無で判定する (バイナリでも読めるよう grep -a を使用)。
    #   - PEM: チェーンを 1 枚ずつに分割してから取り込む
    #           (keytool -importcert は PEM 連結の 2 枚目以降を無視するため)
    #   - DER: 1 ファイル 1 証明書。keytool がそのまま読める
    # --------------------------------------------------------------
    if LC_ALL=C grep -qa -- '-----BEGIN CERTIFICATE-----' "${CRT_FILE}"; then
        echo "==> Detected PEM (Base64) encoded certificate: ${SRC_LABEL}"
        awk -v dir="${SPLIT_DIR}" '
            /-----BEGIN CERTIFICATE-----/ { n++; write=1 }
            write { print > sprintf("%s/cert-%02d", dir, n) }
            /-----END CERTIFICATE-----/   { write=0 }
        ' "${CRT_FILE}"
    else
        echo "==> Detected DER (binary) encoded certificate: ${SRC_LABEL}"
        cp "${CRT_FILE}" "${SPLIT_DIR}/cert-01"
    fi

    COUNT=0
    IMPORTED=0
    for CERT in "${SPLIT_DIR}"/cert-*; do
        [[ -e "${CERT}" ]] || break

        # 取り込む前に証明書として解釈できるかを検証する。
        # (テキストだが証明書ではない / 壊れた DER などを早期に弾く)
        if ! keytool "${KEYTOOL_OPTS[@]}" -printcert -file "${CERT}" </dev/null >/dev/null 2>&1; then
            echo "ERROR: not a valid X.509 certificate: ${SRC_LABEL}" >&2
            echo "       PEM (-----BEGIN CERTIFICATE-----) または DER 形式の" >&2
            echo "       cacert.crt を渡しているか確認すること。" >&2
            exit 1
        fi

        COUNT=$((COUNT + 1))
        SEQ=$(( ${SRC_SEQ["${SRC_NAME}"]:-0} + 1 ))
        SRC_SEQ["${SRC_NAME}"]="${SEQ}"
        ALIAS="${SRC_NAME}-ca-${SEQ}"
        echo "==> Importing certificate as alias '${ALIAS}'"
        # どの証明書を焼き込んだかをビルドログに残す (有効期限の確認用)。
        # keytool の出力はロケール依存のため、-J-Duser.language で英語に固定して
        # 見出し (Owner/Issuer/Valid from) を安定させる。
        keytool "${KEYTOOL_OPTS[@]}" -J-Duser.language=en -J-Duser.country=US \
            -printcert -file "${CERT}" </dev/null \
            | sed -n '/^Owner:/p; /^Issuer:/p; /^Valid from:/p'

        # -importcert も進捗を stderr に出すため、失敗時のみ内容を見せる。
        IMPORT_LOG=""
        IMPORT_RC=0
        IMPORT_LOG="$(timeout "${KEYTOOL_TIMEOUT}" \
            keytool "${KEYTOOL_OPTS[@]}" -J-Duser.language=en -J-Duser.country=US \
                -importcert -noprompt \
                -alias "${ALIAS}" \
                -file  "${CERT}" \
                -keystore  "${OUT_STORE}" \
                -storetype PKCS12 \
                -storepass "${STORE_PASS}" </dev/null 2>&1)" || IMPORT_RC=$?
        if [[ "${IMPORT_RC}" -ne 0 ]]; then
            echo "${IMPORT_LOG}" >&2
            echo "ERROR: failed to import ${SRC_LABEL} as '${ALIAS}' (exit ${IMPORT_RC})" >&2
            exit 1
        fi

        # 全く同じ証明書が既にストア内にある場合 (JDK cacerts 由来、または
        # 複数ソース間での重複)、keytool -importcert -noprompt は追加を行わずに
        # 正常終了する。エイリアスが作られたかどうかで取り込み結果を判定し、
        # 重複はスキップ扱いにしてビルドを継続する。
        LIST_LOG=""
        LIST_RC=0
        LIST_LOG="$(keytool "${KEYTOOL_OPTS[@]}" -J-Duser.language=en -J-Duser.country=US \
            -list \
            -alias "${ALIAS}" \
            -keystore  "${OUT_STORE}" \
            -storetype PKCS12 \
            -storepass "${STORE_PASS}" </dev/null 2>&1)" || LIST_RC=$?
        if [[ "${LIST_RC}" -eq 0 ]]; then
            echo "${LIST_LOG}"
            IMPORTED=$((IMPORTED + 1))
        else
            echo "==> Skipped '${ALIAS}': identical certificate is already in the truststore"
            echo "${IMPORT_LOG}"
            # 重複でエイリアスが作られなかった場合も番号は消費する
            # (ログ上の '<name>-ca-<n>' と証明書が 1 対 1 で対応するようにする)。
        fi
    done

    if [[ "${COUNT}" -eq 0 ]]; then
        echo "ERROR: no certificate found in ${SRC_LABEL} (source '${SRC_NAME}')" >&2
        exit 1
    fi

    TOTAL_FOUND=$((TOTAL_FOUND + COUNT))
    TOTAL_IMPORTED=$((TOTAL_IMPORTED + IMPORTED))
    SUMMARY+=("${SRC_NAME}: ${IMPORTED} imported / $((COUNT - IMPORTED)) skipped (duplicate) <- ${SRC_LABEL}")
done

echo "------------------------------------------------------------------"
echo "==> Done. ${TOTAL_IMPORTED} of ${TOTAL_FOUND} certificate(s) imported into ${OUT_STORE}"
for LINE in "${SUMMARY[@]}"; do
    echo "      ${LINE}"
done
