#!/bin/sh
# 使い方: make-dist.sh <タグ> <期待するコミット>
#
# 上流のgitリポジトリから <タグ> を取得し、そのコミットが <期待するコミット> と一致することを
# 確かめてから(scripts/import-upstream.sh が git.zabbix.com と GitHub のミラーの両方で照合した値)、
# 公式の配布手順(bootstrap → configure → dbschema → gettext → go mod vendor → make dist)で
# /out/zabbix-<バージョン>.tar.gz を作る。
set -eu

ZBX_GIT_URL="${ZBX_GIT_URL:-https://git.zabbix.com/scm/zbx/zabbix.git}"

fail() {
	echo "!! make-dist: $1" >&2
	exit 1
}

[ "$#" -eq 2 ] || fail "usage: make-dist.sh <tag> <expected-commit>"
tag="$1"
expected="$2"

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${tag}" "${ZBX_GIT_URL}" /src
cd /src
actual="$(git rev-parse HEAD)"
[ "${actual}" = "${expected}" ] \
	|| fail "tag ${tag} resolved to ${actual}, expected ${expected}; refusing to build"

# 公式tarballと同じ11桁の短縮リビジョンにする(浅いcloneだとgitは7桁にする)。
git config core.abbrev 11
# dbschema.c の表の並びはPerlのハッシュ順で決まるので、同じタグから毎回同じtarballになるよう固定する。
export PERL_HASH_SEED=0 PERL_PERTURB_KEYS=0
# go mod vendor は go.mod の版より古いGoでは動かないが、ツールチェーンの自動ダウンロードはしない。
export GOTOOLCHAIN=local GOFLAGS=-mod=mod GOTELEMETRY=off

./bootstrap.sh
./configure \
	--enable-server --enable-proxy --enable-agent --enable-agent2 \
	--with-mysql --with-libpcre2 --with-openssl --with-libcurl --with-libxml2 \
	--with-net-snmp --with-ares --with-apm \
	--silent
make -s dbschema
make -s gettext
# 公式tarballは src/go/vendor を含む(ビルド時にネットワークからGoモジュールを取らずに済む)。
# go.sum で検証された内容だけが入る。
(cd src/go && go mod vendor)
make -s dist

version="${tag}"
tarball="zabbix-${version}.tar.gz"
[ -f "${tarball}" ] || fail "make dist did not produce ${tarball}"
# automakeがtarを見つけられないと、エラーにならずに空のtarballができる(過去に実際に起きた)。
entries="$(tar -tzf "${tarball}" | wc -l)"
[ "${entries}" -gt 1000 ] || fail "${tarball} has only ${entries} entries; the dist is broken"

mkdir -p /out
cp "${tarball}" /out/
printf '%s\n' "${actual}" > /out/commit
echo "make-dist: ${tarball} (${entries} entries) from ${tag} @ ${actual}"
