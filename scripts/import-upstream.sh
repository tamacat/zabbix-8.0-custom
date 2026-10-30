#!/usr/bin/env bash
# 上流Zabbixの新しいバージョン(8.0系列。alpha/beta/rcを含む)を sources/ へ取り込む。
#
#   ./scripts/import-upstream.sh [--source auto|cdn|git] <version>     例: 8.0.0rc4, 8.0.0, 8.0.1
#
# 行うこと:
#   1. ソースtarballを入手して検証する。
#      - cdn: 公式CDN(cdn.zabbix.com)のtarballと、同じ場所の .sha256 で照合する(正式リリースは
#        stable/、プレリリースは development/ に置かれる)。
#      - git: CDNにtarballが無いプレリリース(例: 8.0.0rc3)は、gitのタグから公式と同じ手順の
#        `make dist` で作る(docker/upstream-dist/)。タグのコミットは git.zabbix.com と GitHub の
#        ミラー(github.com/zabbix/zabbix)の両方で引き、一致しなければ止める。
#      - auto(既定): cdn を試し、tarballが無ければ git。チェックサムが合わない場合は git へ
#        切り替えずに止める(改ざん・破損の可能性があるため)。
#   2. 展開した無改変のツリーを sources/zabbix-<version>/ に置き、旧バージョンのツリーを消して、
#      それだけを1つのコミットにする(SASTゲートの差分の基準。data/upstream-import-ref)。
#   3. 旧バージョンに当てていたこのプロジェクトのパッチ(旧 upstream-import-ref から取り込み直前
#      までの sources/ の差分)を、新しいツリーへ3-wayで当て直す。
#   4. .env.example・Dockerfile・スクリプト・テスト・README の旧バージョン表記を新バージョンに
#      置き換え、data/upstream-import-ref を新しい取り込みコミットにする。
#
# 3・4 はコミットせず作業ツリーに残す。差分を確認し、衝突があれば解消してからテスト・ビルド・
# スキャンを行い、自分でコミットする(最後に表示する手順を参照)。8.0系列以外へは上げない。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ZBX_GIT_URL="${ZBX_GIT_URL:-https://git.zabbix.com/scm/zbx/zabbix.git}"
ZBX_GIT_MIRROR_URL="${ZBX_GIT_MIRROR_URL:-https://github.com/zabbix/zabbix.git}"
ALPINE_VERSION="${ALPINE_VERSION:-3.24}"

fail() {
	echo "!! import-upstream: $1" >&2
	exit 1
}

usage() {
	echo "usage: $0 [--source auto|cdn|git] <version>" >&2
	exit 2
}

SOURCE=auto
while [ "$#" -gt 0 ]; do
	case "$1" in
		--source) [ "$#" -ge 2 ] || usage; SOURCE="$2"; shift 2 ;;
		--source=*) SOURCE="${1#--source=}"; shift ;;
		-h|--help) usage ;;
		-*) usage ;;
		*) break ;;
	esac
done
[ "$#" -eq 1 ] || usage
NEW="$1"
case "${SOURCE}" in auto|cdn|git) ;; *) usage ;; esac

if python3 -c "import sys" >/dev/null 2>&1; then
	PY=python3
elif python -c "import sys" >/dev/null 2>&1; then
	PY=python
else
	fail "python3 (or python) is required"
fi

"${PY}" -m release_tools.cli zabbix-version --version "${NEW}" >/dev/null \
	|| fail "'${NEW}' is not a Zabbix 8.0 version"

CURRENT="$(sed -n 's/^ZABBIX_VERSION=//p' .env.example | head -n 1)"
[ -n "${CURRENT}" ] || fail ".env.example has no ZABBIX_VERSION="
[ "${CURRENT}" != "${NEW}" ] || fail "${NEW} is already the current version"
OLD_DIR="sources/zabbix-${CURRENT}"
NEW_DIR="sources/zabbix-${NEW}"
[ ! -e "${NEW_DIR}" ] || fail "${NEW_DIR} already exists"

[ -z "$(git status --porcelain)" ] || fail "the working tree is not clean; commit or stash first"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
TARBALL="${WORKDIR}/zabbix-${NEW}.tar.gz"
PROVENANCE=""

sha256_of() {
	sha256sum "$1" | awk '{print $1}'
}

# 公式CDNから取得する。tarballが無ければ1を返す(autoならgitへ)。チェックサムの不一致は即停止。
fetch_cdn() {
	local url expected actual
	while read -r url; do
		[ -n "${url}" ] || continue
		echo "-- trying ${url}"
		if ! curl -fsSL -o "${TARBALL}" "${url}"; then
			continue
		fi
		curl -fsSL -o "${TARBALL}.sha256" "${url}.sha256" \
			|| fail "${url} exists but ${url}.sha256 does not; refusing an unverified tarball"
		# 公式の .sha256 はハッシュだけの1行(ファイル名なし)。ファイル名付きの形式でも先頭を取る。
		expected="$(awk 'NR==1{print tolower($1)}' "${TARBALL}.sha256")"
		actual="$(sha256_of "${TARBALL}")"
		[ "${expected}" = "${actual}" ] \
			|| fail "SHA-256 mismatch for ${url}: expected ${expected}, got ${actual}"
		PROVENANCE="Source: ${url}
SHA-256: ${actual} (matches ${url}.sha256)"
		return 0
	done < <("${PY}" -m release_tools.cli zabbix-version --version "${NEW}" --cdn-urls)
	rm -f "${TARBALL}" "${TARBALL}.sha256"
	return 1
}

# タグのコミットを引く(注釈付きタグは ^{} で中身のコミットにする)。
tag_commit() {
	local out
	out="$(git ls-remote "$1" "refs/tags/${NEW}" "refs/tags/${NEW}^{}")" || return 1
	{ printf '%s\n' "${out}" | awk -v t="refs/tags/${NEW}^{}" '$2==t{print $1; f=1} END{exit !f}'; } \
		|| printf '%s\n' "${out}" | awk -v t="refs/tags/${NEW}" '$2==t{print $1}'
}

fetch_git() {
	local commit mirror_commit cid sha dest
	commit="$(tag_commit "${ZBX_GIT_URL}")" || fail "git ls-remote ${ZBX_GIT_URL} failed"
	[ -n "${commit}" ] || fail "tag ${NEW} does not exist in ${ZBX_GIT_URL}"
	mirror_commit="$(tag_commit "${ZBX_GIT_MIRROR_URL}")" || fail "git ls-remote ${ZBX_GIT_MIRROR_URL} failed"
	[ "${commit}" = "${mirror_commit}" ] \
		|| fail "tag ${NEW} is ${commit} in ${ZBX_GIT_URL} but '${mirror_commit}' in ${ZBX_GIT_MIRROR_URL}"
	echo "-- tag ${NEW} = ${commit} (git.zabbix.com and the GitHub mirror agree)"

	docker build -q -f docker/upstream-dist/Dockerfile \
		--build-arg "ALPINE_VERSION=${ALPINE_VERSION}" \
		-t zabbix-upstream-dist:local . >/dev/null \
		|| fail "building docker/upstream-dist failed"
	# Git Bash(MSYS)は "x:/out/..." のような引数をWindowsのパスへ書き換えてしまうので、docker へ渡す
	# 引数は変換させない。コピー先だけは自分でWindowsのパスにする。
	dest="${TARBALL}"
	if command -v cygpath >/dev/null 2>&1; then
		dest="$(cygpath -w "${TARBALL}")"
	fi
	cid="$(MSYS2_ARG_CONV_EXCL='*' docker create -e "ZBX_GIT_URL=${ZBX_GIT_URL}" zabbix-upstream-dist:local "${NEW}" "${commit}")"
	if ! docker start -a "${cid}"; then
		docker rm -f "${cid}" >/dev/null 2>&1 || true
		fail "make dist from tag ${NEW} failed"
	fi
	MSYS2_ARG_CONV_EXCL='*' docker cp "${cid}:/out/zabbix-${NEW}.tar.gz" "${dest}" >/dev/null
	docker rm "${cid}" >/dev/null
	sha="$(sha256_of "${TARBALL}")"
	PROVENANCE="Source: git tag ${NEW} @ ${commit}
  (${ZBX_GIT_URL}; the same commit in ${ZBX_GIT_MIRROR_URL})
Built with docker/upstream-dist (bootstrap, configure, dbschema, gettext,
go mod vendor, make dist) because no official tarball was published for it.
SHA-256 of the generated tarball: ${sha}"
}

case "${SOURCE}" in
	cdn) fetch_cdn || fail "no official tarball for ${NEW} on cdn.zabbix.com" ;;
	git) fetch_git ;;
	auto) fetch_cdn || { echo "-- no official tarball for ${NEW}; building it from the git tag"; fetch_git; } ;;
esac

top="$(tar -tzf "${TARBALL}" | head -n 1 | cut -d/ -f1)"
[ "${top}" = "zabbix-${NEW}" ] || fail "unexpected top-level directory '${top}' in the tarball"

# --- 2. 無改変のツリーだけのコミット -----------------------------------------------
PRE_HEAD="$(git rev-parse HEAD)"
OLD_REF="$(tr -d '[:space:]' < data/upstream-import-ref 2>/dev/null || true)"

mkdir -p sources
tar -xzf "${TARBALL}" -C sources/
if [ -d "${OLD_DIR}" ]; then
	git rm -r -q "${OLD_DIR}"
fi
git add -f "${NEW_DIR}"
# 実行ビットはtarballの記録どおりにする(Windowsのチェックアウトなど core.fileMode=false の環境では
# git add が実行ビットを拾わず、configure 等が 100644 で記録されてしまうため)。
"${PY}" - "${TARBALL}" <<'PYEOF' | sed 's#^#sources/#' | tr '\n' '\0' | xargs -0 -r -n 200 git update-index --chmod=+x --
import sys, tarfile
with tarfile.open(sys.argv[1]) as tf:
    for m in tf:
        if m.isfile() and m.mode & 0o111:
            print(m.name)
PYEOF
git commit -q -F - <<EOF
upstream: import Zabbix ${NEW} (unmodified)

${PROVENANCE}

This commit holds the unmodified upstream tree only (and removes ${OLD_DIR}
if it was present), so that data/upstream-import-ref can point at it and the
SAST gate can diff our patches against it.
EOF
IMPORT_COMMIT="$(git rev-parse HEAD)"
echo "-- committed the unmodified tree: ${IMPORT_COMMIT}"

# --- 3. パッチの当て直し ------------------------------------------------------------
CONFLICTS=0
if [ -n "${OLD_REF}" ] && git cat-file -e "${OLD_REF}^{commit}" 2>/dev/null \
	&& git cat-file -e "${PRE_HEAD}:${OLD_DIR}" 2>/dev/null; then
	git diff --binary --full-index --relative="${OLD_DIR}/" "${OLD_REF}" "${PRE_HEAD}" > "${WORKDIR}/patches.diff"
	if [ -s "${WORKDIR}/patches.diff" ]; then
		echo "-- re-applying our patches ($(grep -c '^diff --git' "${WORKDIR}/patches.diff") files) onto ${NEW_DIR}"
		if ! git apply --3way --directory="${NEW_DIR}" "${WORKDIR}/patches.diff"; then
			CONFLICTS=1
		fi
	fi
else
	echo "-- no previous import to carry patches from (data/upstream-import-ref is empty or ${OLD_DIR} is absent)"
fi

# --- 4. バージョン表記の置き換え ----------------------------------------------------
printf '%s\n' "${IMPORT_COMMIT}" > data/upstream-import-ref
# 8.0.1 が 8.0.10 や 8.0.1rc1 の一部に一致しないよう、前後を区切って置き換える。
mapfile -t files < <(git grep -l -F "${CURRENT}" -- . ':!sources/' ':!data/sast-baseline/' || true)
if [ "${#files[@]}" -gt 0 ]; then
	OLD="${CURRENT}" NEW="${NEW}" perl -pi -e \
		's/(?<![0-9.])\Q$ENV{OLD}\E(?![0-9]|alpha|beta|rc)/$ENV{NEW}/g' "${files[@]}"
fi

echo ""
echo "=================================================================="
echo "Imported Zabbix ${NEW} (was ${CURRENT})."
if [ "${CONFLICTS}" -ne 0 ]; then
	echo "!! Some patches did not apply cleanly. Resolve the conflict markers / .rej"
	echo "!! files under ${NEW_DIR} before going on (git status shows them)."
fi
cat <<EOF
Not committed yet: re-applied patches, version strings, data/upstream-import-ref.
Next:
  git status && git diff                     # review
  python3 -m pytest tests -q && bats tests/scripts
  ./scripts/scan-sast.sh --update-baseline   # review git diff data/sast-baseline/
  ./scripts/build-images.sh && ./scripts/ci-pipeline.sh
  git commit -a                              # e.g. "8.0: move to ${NEW}"
Check the upstream release notes for new configuration parameters, packages
and PHP/Go version requirements (docker/*/entrypoint.sh, docker/*/Dockerfile).
EOF
