#!/bin/bash
#
# cacert-secret-args.sh [certs-dir] [bundle-path]
#
# certs ディレクトリ (既定: secrets/certs) 配下の <name>/<証明書ファイル> を走査して
# 1 つの tar アーカイブへまとめ、docker build へ渡す --secret 引数を
# 標準出力へ生成する。証明書のファイル名・拡張子は問わない (後述)。
#
# BuildKit のシークレットはディレクトリをマウントできない (moby/buildkit#970)
# ため、certs ディレクトリごと 1 ファイルに詰めて単一のシークレット
# (id=cacerts) として渡す。これにより **証明書ソースが増えても
# Dockerfile / docker build コマンドの変更は不要**になる
# (配置するのは secrets/certs/<name>/ 配下の証明書ファイルだけ)。
# アーカイブは base/scripts/build-truststore.sh がビルドコンテナ内で展開し、
# サブディレクトリ名をソース名 (エイリアス接頭辞) として取り込む。
#
# 使い方 (リポジトリルートで実行):
#   DOCKER_BUILDKIT=1 docker build \
#     $(bash scripts/cacert-secret-args.sh) \
#     -t eap81-extraslb-base:1.0 base/
#
#   ※ 診断メッセージは stderr、生成する引数のみ stdout へ出す。
#   ※ 実行ビットに依存しないよう bash 経由で呼ぶ想定。Windows では Git Bash 等で実行する。
#   ※ 生成するアーカイブは既定で <certs-dir> の親へ cacerts-bundle.tar として
#      置く (secrets/ 配下なので .gitignore 済み)。第 2 引数または環境変数
#      BUNDLE_PATH で変更できる。ビルド後は削除してよい。
#   ※ 取り込む対象は各ソースディレクトリ直下の全ファイル。
#      **ファイル名・拡張子は問わない** (cacert.crt でなくてよい)。証明書かどうかは
#      名前ではなく中身 (PEM ヘッダ / DER のマジックナンバー) で判定し、
#      証明書でないファイル (README, Thumbs.db 等) は警告付きで読み飛ばす。
#      名前で絞り込みたい場合のみ CERT_GLOBS='*.crt *.pem' のように指定する。
#      シークレット ID は SECRET_ID で上書きできる (Dockerfile 側と揃えること)。
set -euo pipefail

CERTS_DIR="${1:-secrets/certs}"
CERTS_DIR="${CERTS_DIR%/}"
BUNDLE_PATH="${2:-${BUNDLE_PATH:-$(dirname "${CERTS_DIR}")/cacerts-bundle.tar}}"
SECRET_ID="${SECRET_ID:-cacerts}"

# 対象とする証明書ファイルのパターン。ここではパターン文字列のまま保持し、
# 展開はソースディレクトリごとに行う (set -f で「カレントディレクトリの
# *.crt にマッチしてしまう」事故を防ぐ)。
# 既定は '*' (= ファイル名を問わない)。証明書かどうかは is_certificate が
# 中身で判定するため、cacert.crt / ca.cer / 拡張子なし等どの名前でも取り込める。
if [[ -n "${CERT_GLOBS:-}" ]]; then
    set -f
    # shellcheck disable=SC2206  # 空白区切りの指定を配列に分割する
    CERT_GLOB_LIST=(${CERT_GLOBS})
    set +f
else
    CERT_GLOB_LIST=('*')
fi

# ファイル名ではなく中身で「証明書ファイルか」を判定する
# (build-truststore.sh 側の形式自動判別と同じ見方)。
#   PEM     … "-----BEGIN CERTIFICATE-----" 行を含む
#             (バイナリ混在でも読めるよう grep -a)
#   PEM/P7B … "-----BEGIN PKCS7-----" 等のチェーンバンドル
#   DER/P7B … ASN.1 SEQUENCE (0x30) + 長さの長形式 (0x81/0x82/0x83) で始まる
#             (X.509 単体も PKCS#7 バンドルも同じ始まり方をする)
# これを通ったファイルだけ tar へ入れることで、ファイル名を自由にしても
# 証明書以外のファイルが混入してビルドが落ちることはない。
is_certificate() {
    local FILE="$1"
    LC_ALL=C grep -Eqa -- '-----BEGIN ([A-Z0-9 ]+ )?CERTIFICATE-----|-----BEGIN PKCS ?#?7' \
        "${FILE}" && return 0
    case "$(LC_ALL=C od -An -tx1 -N2 "${FILE}" | tr -d '[:space:]')" in
        3081|3082|3083) return 0 ;;
        *)              return 1 ;;
    esac
}

if [[ ! -d "${CERTS_DIR}" ]]; then
    echo "ERROR: certs directory not found: ${CERTS_DIR}" >&2
    echo "       ${CERTS_DIR}/<name>/<証明書ファイル> の構成で配置すること (ファイル名は任意)。" >&2
    echo "       例: ${CERTS_DIR}/extraslb/cacert.crt, ${CERTS_DIR}/others/rootCA.pem" >&2
    exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
    echo "ERROR: tar command not found" >&2
    echo "       Windows では Git Bash (tar 同梱) で実行すること。" >&2
    exit 1
fi

shopt -s nullglob

FOUND_NAMES=()
REL_PATHS=()

for DIR in "${CERTS_DIR}"/*/; do
    NAME="$(basename "${DIR}")"

    # ソースディレクトリ直下の証明書ファイルを集める。
    # 1 ソースに複数枚 (ルート + 中間など) 置いてもよい。
    FILES=()
    for GLOB in "${CERT_GLOB_LIST[@]}"; do
        for F in "${DIR}"${GLOB}; do
            [[ -f "${F}" ]] || continue
            if [[ ! -s "${F}" ]]; then
                echo "WARN: skipped '${NAME}/$(basename "${F}")': ファイルが空です" >&2
                continue
            fi
            # 名前ではなく中身で選別する (証明書以外の同梱ファイルを除く)
            if ! is_certificate "${F}"; then
                echo "WARN: skipped '${NAME}/$(basename "${F}")': PEM/DER/PKCS#7 の証明書ではありません" >&2
                continue
            fi
            FILES+=("${F}")
        done
    done

    if [[ "${#FILES[@]}" -eq 0 ]]; then
        echo "WARN: skipped '${NAME}': ${DIR} に証明書ファイルがありません (対象パターン: ${CERT_GLOB_LIST[*]})" >&2
        continue
    fi

    FOUND_NAMES+=("${NAME}")
    for F in "${FILES[@]}"; do
        # tar へは certs ディレクトリからの相対パス (<name>/<file>) で入れる。
        # 展開側はこの <name> をソース名 = エイリアス接頭辞として使う。
        REL_PATHS+=("${F#"${CERTS_DIR}/"}")
    done
done

if [[ "${#FOUND_NAMES[@]}" -eq 0 ]]; then
    echo "ERROR: no certificate found under ${CERTS_DIR}/*/" >&2
    echo "       ${CERTS_DIR}/<name>/<証明書ファイル> の構成で配置すること (ファイル名は任意)。" >&2
    echo "       PEM (-----BEGIN CERTIFICATE-----) / DER / PKCS#7 のいずれかであること。" >&2
    exit 1
fi

# 対象ファイルを明示列挙して固める。ディレクトリごと固めないのは、
# .DS_Store や README のような証明書以外のファイルを混入させないため
# (混入すると build-truststore.sh が「証明書ではない」で失敗する)。
rm -f "${BUNDLE_PATH}"
mkdir -p "$(dirname "${BUNDLE_PATH}")"
tar -cf "${BUNDLE_PATH}" -C "${CERTS_DIR}" "${REL_PATHS[@]}"

echo "==> certificate sources: ${FOUND_NAMES[*]}" >&2
echo "==> bundled ${#REL_PATHS[@]} file(s) into ${BUNDLE_PATH}" >&2
printf -- '--secret id=%s,src=%s\n' "${SECRET_ID}" "${BUNDLE_PATH}"
