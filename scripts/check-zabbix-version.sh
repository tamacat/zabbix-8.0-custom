#!/usr/bin/env bash
# 上流Zabbixに、取り込み済みより新しい8.0系列のバージョンが出ていないかを確認する。
#
# 公式のコンテナイメージは更新が遅いので、このプロジェクトは上流のソースのリリース(gitのタグ)に
# 直接追従する。このスクリプトがその目印で、新しいバージョンがあれば失敗し、取り込みのコマンドを
# 表示する(scripts/check-php-version.sh と同じく、週次のCIで動かす)。
#
# どれを「新しい」とするかは release_tools/zabbix_version.py の upstream_update と同じ:
#   - 現在より新しい正式リリース(8.0.0, 8.0.1, ...)があれば、それを最優先にする。
#   - 現在がプレリリース(8.0.0rc3 など)で、新しい正式リリースがまだ無ければ、次のプレリリース。
#   - 現在が正式リリースなら、プレリリース(8.0.2rc1 など)は追従の対象にしない。
#
# 使用法: scripts/check-zabbix-version.sh
#   ZBX_GIT_URL  タグを引くgitリポジトリ(既定: https://git.zabbix.com/scm/zbx/zabbix.git)
#   ENV_FILE     取り込み済みのバージョン(ZABBIX_VERSION=)を読むファイル(既定: .env.example)
#
# BR6.1: 失敗時は自動リトライを行わない。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ZBX_GIT_URL="${ZBX_GIT_URL:-https://git.zabbix.com/scm/zbx/zabbix.git}"
ENV_FILE="${ENV_FILE:-.env.example}"

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

if python3 -c "import sys" >/dev/null 2>&1; then
	PY=python3
elif python -c "import sys" >/dev/null 2>&1; then
	PY=python
else
	fail "python3(またはpython)の実行可能なインタプリタが見つかりません"
fi

[ -f "${ENV_FILE}" ] || fail "${ENV_FILE} が見つかりません"
CURRENT="$(sed -n 's/^ZABBIX_VERSION=//p' "${ENV_FILE}" | head -n 1)"
[ -n "${CURRENT}" ] || fail "${ENV_FILE} に 'ZABBIX_VERSION=' が見つかりません"
LINE="$("${PY}" -m release_tools.cli zabbix-version --version "${CURRENT}" --field line)" \
	|| fail "${ENV_FILE} の ZABBIX_VERSION=${CURRENT} は追従対象の系列のバージョンではありません"

# 注釈付きタグは ^{} 付きの行も出るので、タグ名だけにして重複を除く。
TAGS="$(git ls-remote --tags --refs "${ZBX_GIT_URL}" "refs/tags/${LINE}.*" 2>/dev/null)" \
	|| fail "上流のタグを取得できませんでした(${ZBX_GIT_URL})"
NAMES="$(printf '%s\n' "${TAGS}" | awk '{print $2}' | sed -n 's#^refs/tags/##p' | sort -u)"
[ -n "${NAMES}" ] || fail "上流に ${LINE} 系列のタグが1つもありません(${ZBX_GIT_URL})。取得先が正しいか確認してください"

NEWER="$(printf '%s\n' "${NAMES}" | "${PY}" -m release_tools.cli zabbix-version --version "${CURRENT}" --upstream-update)" \
	|| fail "バージョンの比較に失敗しました"

echo "Zabbix ${LINE}系列: 取り込み済み=${CURRENT}  上流の追従先=${NEWER:-なし}"

if [ -z "${NEWER}" ]; then
	echo "Zabbix version check: up to date"
	exit 0
fi

echo "Zabbix version check: OUTDATED — ${NEWER} is available upstream. Import it with:" >&2
echo "  ./scripts/import-upstream.sh ${NEWER}" >&2
exit 1
