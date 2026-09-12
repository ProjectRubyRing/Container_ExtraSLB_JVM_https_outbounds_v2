#!/bin/bash
#
# provision-application-keystore.sh <server-config.xml> [owner]
#
# JBoss EAP / WildFly 標準設定に含まれる **インバウンド (サーバ側) HTTPS 用**
# キーストア (既定では applicationKS -> standalone/configuration/application.keystore)
# を、EAP 自身が遅延生成するのと同じ内容で **事前に** 用意する。
#
# ------------------------------------------------------------------
# 【何を解決するのか】
#   標準の standalone.xml には次の 3 リソースが最初から入っている。
#
#     <key-store name="applicationKS">
#         <credential-reference clear-text="password"/>
#         <implementation type="JKS"/>
#         <file path="application.keystore" relative-to="jboss.server.config.dir"/>
#     </key-store>
#     <key-manager name="applicationKM" key-store="applicationKS"
#                  generate-self-signed-certificate-host="localhost"> ... </key-manager>
#     <server-ssl-context name="applicationSSC" key-manager="applicationKM"/>
#
#   ところが application.keystore ファイルはディストリビューションに同梱されておらず、
#   **初回のインバウンド HTTPS ハンドシェイク時に遅延生成**される。
#   一方 Elytron の key-store リソースは ACTIVE な MSC サービスとして
#   「誰も参照していなくても」ブートのたびに起動するため、ファイルが無い間は
#   毎起動この 2 行が出る:
#
#     WARN [org.wildfly.extension.elytron] WFLYELY00023:
#          KeyStore file '.../application.keystore' does not exist. Used blank.
#     WARN [org.wildfly.extension.elytron] WFLYELY01084:
#          KeyStore ... not found, it will be auto-generated on first use ...
#
#   コンテナは起動のたびにイメージの初期状態へ戻るため、この警告は毎回出続ける。
#   本スクリプトで「EAP が自分で作るはずだったもの」を先に置いておけば、
#   ログを握りつぶすことなく警告の原因そのものが無くなる。
#   (背景・検証記録: docs/wflyely00023-application-keystore.md)
#
# ------------------------------------------------------------------
# 【安全側に倒すための判定条件】
#   誤って「本来利用者が用意すべきキーストア」や「トラストストア」を
#   自己署名鍵入りで作ってしまうと、単なる警告が
#     - ブート失敗 (キーストアのパスワード不一致)
#     - 不正な信頼アンカーの混入 (JDK の TrustManagerFactory は
#       PrivateKeyEntry のチェーン先頭も信頼済み証明書として扱う)
#   に化ける。そこで **次を全て満たす key-store だけ**を対象にする。
#
#     1. <file relative-to="jboss.server.config.dir"> であること
#     2. path が式 (${...}) やディレクトリ区切りを含まない単純なファイル名であること
#     3. 実ファイルがまだ存在しないこと
#     4. credential-reference clear-text が式ではなくリテラルであること
#        (パスワードを確定できないなら触らない)
#     5. generate-self-signed-certificate-host を持つ key-manager から
#        参照されていること
#        ★ これが本質的な条件。「EAP 自身が自己署名証明書を生成する対象」だと
#          設定ファイルが明言しているものだけを先回りして作る、という意味になり、
#          動作は EAP の既定と完全に等価になる。
#
#   条件に合わない key-store は理由付きで読み飛ばす (処理は成功扱い)。
#   本プロジェクトが CLI で追加する extraslb-trust-store は
#   path が ${env.EXTRASLB_TRUSTSTORE_PATH:...} という式で relative-to も持たないため、
#   条件 1/2 で確実に除外される。
#
# ------------------------------------------------------------------
# 【生成内容】EAP (WildFly Elytron) の遅延生成と同一形状
#     エイリアス       : server
#     識別名           : CN=<generate-self-signed-certificate-host の値>
#     鍵               : RSA 2048bit / SHA256withRSA
#     有効期間         : 3650 日
#     ストア形式       : <implementation type> の値 (既定 JKS)
#     ストアパスワード : credential-reference clear-text の値 (鍵パスワードも同じ)
#     拡張             : SubjectKeyIdentifier のみ (SAN は付かない。EAP の生成物と同じ)
#
# ------------------------------------------------------------------
# 【使い方】
#   ビルド時 (base/Dockerfile):
#     provision-application-keystore.sh "${CONF_DIR}/standalone.xml" "185:0"
#   起動時 (entrypoint.sh):
#     provision-application-keystore.sh "${CONF_DIR}/${SERVER_CONFIG}"
#
#   ※ 冪等。ファイルが既にあれば何もしない
#     (ビルド時に作られていれば起動時の呼び出しは即 no-op)。
#   ※ 本スクリプトの失敗でビルド / 起動を止めることはしない。
#     元々「警告が出るだけ」の事象であり、対処の失敗がそれより重い障害に
#     なっては本末転倒なため。
set -uo pipefail

PREFIX="[app-keystore]"
say()  { echo "==> ${PREFIX} $*"; }
warn() { echo "==> ${PREFIX} WARN: $*" >&2; }

SERVER_CONFIG_PATH="${1:-}"
OWNER="${2:-}"

if [[ -z "${SERVER_CONFIG_PATH}" ]]; then
    warn "サーバ設定ファイルのパスが指定されていません (usage: $0 <server-config.xml> [owner])"
    exit 0
fi
if [[ ! -r "${SERVER_CONFIG_PATH}" ]]; then
    warn "サーバ設定ファイルが読めないためスキップします: ${SERVER_CONFIG_PATH}"
    exit 0
fi
if ! command -v keytool >/dev/null 2>&1; then
    warn "keytool が見つからないためスキップします (JDK 非同梱のイメージ?)"
    exit 0
fi

CONF_DIR="$(dirname "${SERVER_CONFIG_PATH}")"

# ------------------------------------------------------------------
# standalone.xml から必要な属性を抜き出す。
#   - 改行位置に依存しないよう、いったん 1 行へ潰してから '<' で改行し直し、
#     「1 要素 = 1 行」に正規化してから走査する。
#   - 属性値の取り出しは直前に空白を要求することで、
#     path= が relative-to= 等へ誤マッチしないようにする。
# 出力 (TSV):
#   KS <name> <type> <clear-text> <file-path> <relative-to>
#   KM <key-store> <generate-self-signed-certificate-host>
# ------------------------------------------------------------------
parse_config() {
    tr '\n' ' ' < "${SERVER_CONFIG_PATH}" | sed 's/</\n</g' | awk '
        function attr(s, k,   re, m) {
            re = "[ \t]" k "=\"[^\"]*\"";
            if (match(s, re)) {
                m = substr(s, RSTART, RLENGTH);
                sub(/^[ \t]/, "", m);
                sub(k "=\"", "", m);
                sub(/"$/, "", m);
                return m;
            }
            return "";
        }
        /^<key-store[ \t>]/ {
            in_ks = 1; ks_name = attr($0, "name");
            ks_type = ""; ks_pw = ""; ks_path = ""; ks_relto = "";
            next;
        }
        in_ks && /^<credential-reference[ \t\/>]/ { ks_pw   = attr($0, "clear-text"); next }
        in_ks && /^<implementation[ \t\/>]/       { ks_type = attr($0, "type");       next }
        in_ks && /^<file[ \t\/>]/ {
            ks_path  = attr($0, "path");
            ks_relto = attr($0, "relative-to");
            next;
        }
        in_ks && /^<\/key-store>/ {
            printf "KS\t%s\t%s\t%s\t%s\t%s\n", ks_name, ks_type, ks_pw, ks_path, ks_relto;
            in_ks = 0;
            next;
        }
        /^<key-manager[ \t>]/ {
            host = attr($0, "generate-self-signed-certificate-host");
            if (host != "") printf "KM\t%s\t%s\n", attr($0, "key-store"), host;
            next;
        }
    '
}

CONFIG_DUMP="$(parse_config)" || CONFIG_DUMP=""

# generate-self-signed-certificate-host を持つ key-manager が参照している key-store か
selfsigned_host_for() {
    local ks="$1"
    printf '%s\n' "${CONFIG_DUMP}" \
        | awk -F'\t' -v ks="${ks}" '$1=="KM" && $2==ks { print $3; exit }'
}

generated=0
skipped=0
present=0

while IFS=$'\t' read -r kind name type pw path relto; do
    [[ "${kind}" == "KS" ]] || continue

    # 条件 1: configuration ディレクトリ配下のファイルであること
    [[ "${relto}" == "jboss.server.config.dir" ]] || continue

    # 条件 2: 式やディレクトリ区切りを含まない単純なファイル名であること
    case "${path}" in
        ''|*'${'*|*/*) continue ;;
    esac

    target="${CONF_DIR}/${path}"

    # 条件 3: まだ存在しないこと (冪等性)
    if [[ -e "${target}" ]]; then
        say "${name}: ${path} は既に存在します (何もしません)"
        present=$((present + 1))
        continue
    fi

    # 条件 5: 「EAP 自身が自己署名証明書を生成する対象」であること
    host="$(selfsigned_host_for "${name}")"
    if [[ -z "${host}" ]]; then
        say "${name}: generate-self-signed-certificate-host を持つ key-manager から参照されていないためスキップします"
        say "  -> このキーストアは利用者が用意すべきものです (WFLYELY00023 が出る場合は配置漏れを確認してください)"
        skipped=$((skipped + 1))
        continue
    fi

    # 条件 4: パスワードがリテラルで確定できること
    if [[ -z "${pw}" || "${pw}" == *'${'* ]]; then
        warn "${name}: credential-reference のパスワードを確定できないためスキップします (式または未設定)"
        warn "  -> 誤ったパスワードで生成するとブート失敗 (キーストア読み込みエラー) になるため、あえて作りません"
        skipped=$((skipped + 1))
        continue
    fi

    store_type="${type:-JKS}"

    # EAP (Elytron) の遅延生成と同じ内容で作る。
    # JKS 指定時に keytool が出す「プロプライエタリ形式」警告は、設定ファイルの
    # type に合わせている以上避けられないため、成功時は出力を伏せ失敗時のみ全文を出す。
    if out="$(keytool -genkeypair \
                -alias server \
                -keyalg RSA -keysize 2048 -sigalg SHA256withRSA -validity 3650 \
                -dname "CN=${host}" \
                -keystore "${target}" -storetype "${store_type}" \
                -storepass "${pw}" -keypass "${pw}" 2>&1)"; then
        # 生成物を読み直し、設定どおりのパスワード / 形式で開けることを確認する
        if keytool -list -keystore "${target}" -storetype "${store_type}" \
                   -storepass "${pw}" -alias server >/dev/null 2>&1; then
            chmod 0640 "${target}" 2>/dev/null || true
            [[ -n "${OWNER}" ]] && { chown "${OWNER}" "${target}" 2>/dev/null || true; }
            say "${name}: ${path} を生成しました (type=${store_type}, alias=server, CN=${host}, 3650 日)"
            say "  -> EAP が初回 HTTPS 接続時に自動生成するものと同じ内容です (WFLYELY00023/01084 が出なくなります)"
            generated=$((generated + 1))
        else
            warn "${name}: 生成した ${path} を設定どおりのパスワード / 形式で開けませんでした。削除します"
            rm -f "${target}" 2>/dev/null || true
            skipped=$((skipped + 1))
        fi
    else
        warn "${name}: ${path} の生成に失敗しました (元々警告が出るだけの事象のため処理は続行します)"
        printf '%s\n' "${out}" >&2
        rm -f "${target}" 2>/dev/null || true
        skipped=$((skipped + 1))
    fi
done <<< "${CONFIG_DUMP}"

if [[ "${generated}" -eq 0 && "${skipped}" -eq 0 && "${present}" -eq 0 ]]; then
    say "生成対象のキーストアはありませんでした ($(basename "${SERVER_CONFIG_PATH}"))"
fi

exit 0
