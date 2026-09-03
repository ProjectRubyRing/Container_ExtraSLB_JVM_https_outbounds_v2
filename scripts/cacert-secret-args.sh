#!/bin/bash
#
# cacert-secret-args.sh [certs-dir] [bundle-path]
#
# certs ディレクトリ (既定: secrets/certs) 配下の <name>/cacert.crt を走査して
# 1 つの tar アーカイブへまとめ、docker build へ渡す --secret 引数を
# 標準出力へ生成する。
#
# BuildKit のシークレットはディレクトリをマウントできない (moby/buildkit#970)
# ため、certs ディレクトリごと 1 ファイルに詰めて単一のシークレット
# (id=cacerts) として渡す。これにより **証明書ソースが増えても
# Dockerfile / docker build コマンドの変更は不要**になる
# (配置するのは secrets/certs/<name>/cacert.crt だけ)。
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
#   ※ 取り込む証明書ファイルは各ソースディレクトリ直下の *.crt / *.pem。
#      証明書のファイル名は CERT_GLOBS で上書きできる。
#      シークレット ID は SECRET_ID で上書きできる (Dockerfile 側と揃えること)。
set -euo pipefail

CERTS_DIR="${1:-secrets/certs}"
CERTS_DIR="${CERTS_DIR%/}"
BUNDLE_PATH="${2:-${BUNDLE_PATH:-$(dirname "${CERTS_DIR}")/cacerts-bundle.tar}}"
SECRET_ID="${SECRET_ID:-cacerts}"

# 対象とする証明書ファイルのパターン。ここではパターン文字列のまま保持し、
# 展開はソースディレクトリごとに行う (set -f で「カレントディレクトリの
# *.crt にマッチしてしまう」事故を防ぐ)。
if [[ -n "${CERT_GLOBS:-}" ]]; then
    set -f
    # shellcheck disable=SC2206  # 空白区切りの指定を配列に分割する
    CERT_GLOB_LIST=(${CERT_GLOBS})
    set +f
else
    CERT_GLOB_LIST=('*.crt' '*.pem')
fi

if [[ ! -d "${CERTS_DIR}" ]]; then
    echo "ERROR: certs directory not found: ${CERTS_DIR}" >&2
    echo "       ${CERTS_DIR}/<name>/cacert.crt の構成で証明書を配置すること。" >&2
    echo "       例: ${CERTS_DIR}/extraslb/cacert.crt, ${CERTS_DIR}/others/cacert.crt" >&2
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
            FILES+=("${F}")
        done
    done

    if [[ "${#FILES[@]}" -eq 0 ]]; then
        echo "WARN: skipped '${NAME}': ${DIR} に証明書 (${CERT_GLOB_LIST[*]}) がありません" >&2
        continue
    fi

    if [[ ! -s "${DIR}cacert.crt" ]]; then
        echo "NOTE: '${NAME}' に cacert.crt がありません (規約外のファイル名で取り込みます)" >&2
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
    echo "       ${CERTS_DIR}/<name>/cacert.crt の構成で証明書を配置すること。" >&2
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
