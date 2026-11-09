# zabbix-proxy(プロキシ、C言語)— Alpine Linuxベースのカスタムイメージ [FR1.4][FR3.1]。
#
# ソースの置き場所は docker/server/Dockerfile 冒頭のコメントと同じ(${ZABBIX_SRC_DIR}、既定
# sources/zabbix-8.0.0)。
#
# docker/server/Dockerfile と同じ構造で、意図的な差分は次の2つ:
# - --with-mysql の代わりに --with-sqlite3(BR5.1: zabbix-proxyのローカルバッファに限り
#   SQLite3を例外として許容する)。
# - --with-apm(8.0の新機能。OTLP/gRPCでAPMのテレメトリを受けるコレクター。プロキシ専用)。公式の
#   zabbix/zabbix-proxy-sqlite3 8.0 と同じく組み込む。既定では起動しない(StartAPMCollector=0)。
#   gRPC/protobuf(C++)の実行時ライブラリが増えるが、どれもAlpineのパッケージなのでTrivyが見る。

ARG ALPINE_VERSION=3.24

FROM alpine:${ALPINE_VERSION} AS builder

ARG ZABBIX_SRC_DIR=sources/zabbix-8.0.0

RUN apk add --no-cache \
		build-base \
		linux-headers \
		pkgconf \
		pcre2-dev \
		c-ares-dev \
		protobuf-dev \
		grpc-dev \
		grpc-plugins \
		sqlite-dev \
		openssl-dev \
		libevent-dev \
		zlib-dev \
		libxml2-dev \
		curl-dev \
		net-snmp-dev

WORKDIR /build
COPY ${ZABBIX_SRC_DIR}/ /build/

# git checkoutはtarball展開時のmtime順序を保持しないため、autotoolsが「ソースの方が
# ビルド成果物より新しい」と誤判定し、このビルドステージには存在しないautomake/aclocal
# の再実行を試みて失敗する(既知のautotools問題。--disable-dependency-trackingとは
# 別種の問題で、それだけでは防げない)。コピーされたツリー全体を同一タイムスタンプへ
# 揃え、再生成条件そのものを成立させない(docker/server/Dockerfileと同じ対応)。
RUN find . -exec touch -d '2000-01-01 00:00:00' {} +

RUN sh ./configure \
		--disable-dependency-tracking \
		--enable-proxy \
		--enable-ipv6 \
		--with-sqlite3 \
		--with-net-snmp \
		--with-libcurl \
		--with-libxml2 \
		--with-openssl \
		--with-libpcre2 \
		--with-ares \
		--with-apm \
	&& make -j"$(nproc)"

FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.title="Zabbix proxy (SQLite3)" \
      org.opencontainers.image.source="https://github.com/tamacat/zabbix-8.0-custom"

# ベースイメージ(alpine:${ALPINE_VERSION})は取得した時点のスナップショットで、その後にAlpineが
# 公開した修正がまだ入っていないことがある(zlib 1.3.2-r0のCVE-2026-85091は、リポジトリに
# 修正版1.3.2-r1があるのにベースイメージが古く、SCAゲートで落ちた)。ビルドのたびに公開済みの
# 修正をすべて取り込む。再現性はビルド日付入りのタグ単位で担保する。
# hadolint ignore=DL3017
RUN apk upgrade --no-cache

RUN apk add --no-cache \
		sqlite-libs \
		pcre2 \
		c-ares \
		libprotobuf \
		grpc-cpp \
		libstdc++ \
		openssl \
		libevent \
		zlib \
		libxml2 \
		libcurl \
		net-snmp-libs \
		fping \
		tzdata \
		ca-certificates \
		su-exec
# fping: プロキシ経由のICMPチェック(icmpping等)用。Zabbixは既定のFpingLocationである/usr/sbin/fpingを
# 実行し、無いとアイテムがサポート外になる。Alpineのパッケージはcap_net_rawを持つので、コンテナにNET_RAWを
# 許せばzabbixユーザーでも動く(compose.ymlが付ける。Dockerは既定で持つがPodmanは持たない)。

RUN addgroup -g 1997 -S zabbix \
	&& adduser -D -S -H -u 1997 -G zabbix -s /sbin/nologin zabbix

COPY --from=builder /build/src/zabbix_proxy/zabbix_proxy /usr/sbin/zabbix_proxy
COPY --from=builder /build/conf/zabbix_proxy.conf /etc/zabbix/zabbix_proxy.conf.default

# db_dataはSQLiteバッファファイル専用の永続領域(BR5.1の例外規定はここに限定される。
# 主データベースはあくまでMySQLであり、このボリュームはproxy自身のローカルバッファのみを保持する)。
# enc_internal: ZBX_TLSPSK・ZBX_TLSCERT等のTLS素材を、ファイルではなく値そのもので渡されたときに
# entrypoint.shが書き出す先。modules: ZBX_LOADMODULEのLoadModulePath。
RUN mkdir -p /etc/zabbix /var/lib/zabbix/db_data /var/lib/zabbix/enc /var/lib/zabbix/enc_internal \
		/var/lib/zabbix/externalscripts /var/lib/zabbix/modules /run/zabbix \
	&& chown -R zabbix:zabbix /etc/zabbix /var/lib/zabbix /run/zabbix

COPY docker/proxy/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/var/lib/zabbix/db_data", "/var/lib/zabbix/enc", "/var/lib/zabbix/externalscripts"]

# USERディレクティブは指定しない — entrypoint.shがsu-exec経由でzabbixユーザーへ降格して
# zabbix_proxyをexecするため(su-exec自体の実行にroot権限が必要。server/Dockerfileと同じ方針)。
EXPOSE 10051

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
	CMD test -f /run/zabbix/zabbix_proxy.pid && kill -0 "$(cat /run/zabbix/zabbix_proxy.pid)" || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
