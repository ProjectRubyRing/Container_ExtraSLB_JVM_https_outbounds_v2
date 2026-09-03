# syntax=docker/dockerfile:1.7
#
# フロントコンテナ: ベースイメージに埋め込まれたトラストストア・
# entrypoint・JBoss CLI 設定をそのまま継承し、WAR の配置のみ行う。
#
#   docker build --build-arg BASE_IMAGE=eap81-extraslb-base:1.0 \
#     -t myapp-front:1.0 front/
ARG BASE_IMAGE=eap81-extraslb-base:1.0

FROM ${BASE_IMAGE}

# uid=185 (jboss), gid=0 は EAP イメージの標準実行ユーザー
COPY --chown=185:0 target/front-app.war ${JBOSS_HOME}/standalone/deployments/

# ENTRYPOINT (entrypoint.sh: JBoss CLI 設定 → EAP 起動) はベースイメージから継承
