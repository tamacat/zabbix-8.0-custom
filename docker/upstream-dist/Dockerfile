# 上流Zabbixのgitタグから、公式配布物と同じ形のソースtarball(`make dist`)を作るためのイメージ。
#
# 8.0.0rc3 のように、公式CDN(cdn.zabbix.com)にtarballが置かれず、gitのタグにしか無いプレリリースを
# 取り込むときに scripts/import-upstream.sh が使う。CDNにtarballがあるバージョン(正式リリース・
# 一部のプレリリース)はそちらを使い、このイメージは使わない。
#
# 公式tarballとの一致は 8.0.0beta2(CDNにもgitにもある)で確認した。違いは autotools の版による
# 生成物(configure・Makefile.in 等)、git短縮リビジョンの桁数、ZABBIX_VERSION_RC_NUM の先頭桁
# (公式はブランチから、ここではタグから作るため 1→2)だけで、ソース・SQL・翻訳・Goのvendorは同じ。
#
# 生成物(configure・database/*/schema.sql・ui/locale/*/frontend.mo・src/go/vendor)を作るのに要る
# ものだけを入れる。--with-apm の生成規則に protoc と grpc_cpp_plugin が要る(無いと make dist が
# OpenTelemetry の .proto を処理できない)。GNU tar が無いと automake が am__tar=false にして、
# 空のtarballを作ってしまう(BusyBoxのtarでは足りない)。

ARG ALPINE_VERSION=3.24

FROM alpine:${ALPINE_VERSION}

# hadolint ignore=DL3018
RUN apk add --no-cache \
		bash \
		git \
		tar \
		xz \
		autoconf \
		automake \
		libtool \
		make \
		build-base \
		linux-headers \
		pkgconf \
		perl \
		gettext \
		go \
		pcre2-dev \
		openssl-dev \
		libevent-dev \
		zlib-dev \
		mariadb-connector-c-dev \
		curl-dev \
		libxml2-dev \
		net-snmp-dev \
		c-ares-dev \
		protobuf-dev \
		grpc-dev \
		grpc-plugins

COPY docker/upstream-dist/make-dist.sh /usr/local/bin/make-dist.sh
RUN chmod +x /usr/local/bin/make-dist.sh

ENTRYPOINT ["/usr/local/bin/make-dist.sh"]
