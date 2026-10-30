#!/usr/bin/env bats
# scripts/check-zabbix-version.sh のテスト。上流のタグ一覧は git ls-remote のスタブで与える。
#
# import-upstream: keep-versions(例のバージョンは固定。上流の取り込みで書き換えない)

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	STUB_BIN="${TEST_TMPDIR}/bin"
	mkdir -p "${STUB_BIN}"
	ENV_FILE="${TEST_TMPDIR}/env"
	printf 'ZABBIX_VERSION=8.0.0rc3\n' > "${ENV_FILE}"
	TAGS_FILE="${TEST_TMPDIR}/tags"

	cat > "${STUB_BIN}/git" <<EOF
#!/bin/sh
if [ "\$1" = "ls-remote" ]; then
	echo "git \$*" >> "${TEST_TMPDIR}/git.log"
	[ -z "\${FAKE_GIT_FAIL:-}" ] || exit 128
	while read -r tag; do
		[ -n "\${tag}" ] && printf '0123456789abcdef0123456789abcdef01234567\trefs/tags/%s\n' "\${tag}"
	done < "${TAGS_FILE}"
	exit 0
fi
exec /usr/bin/git "\$@"
EOF
	chmod +x "${STUB_BIN}/git"
}

teardown() {
	rm -rf "${TEST_TMPDIR}"
}

run_check() {
	cd "${REPO_ROOT}"
	run env PATH="${STUB_BIN}:${PATH}" ENV_FILE="${ENV_FILE}" "$@" bash scripts/check-zabbix-version.sh
}

@test "取り込み済みが最新なら成功し、8.0系列のタグだけを問い合わせる" {
	printf '8.0.0rc1\n8.0.0rc2\n8.0.0rc3\n' > "${TAGS_FILE}"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"up to date"* ]]
	grep -q "refs/tags/8.0.\*" "${TEST_TMPDIR}/git.log"
}

@test "新しいrcがあれば失敗し、取り込みのコマンドを示す" {
	printf '8.0.0rc3\n8.0.0rc4\n' > "${TAGS_FILE}"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"OUTDATED"* ]]
	[[ "$output" == *"./scripts/import-upstream.sh 8.0.0rc4"* ]]
}

@test "rcの間に正式リリースが出たら、それを追従先にする" {
	printf '8.0.0rc4\n8.0.0\n8.0.1rc1\n' > "${TAGS_FILE}"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"import-upstream.sh 8.0.0"* ]]
	[[ "$output" != *"import-upstream.sh 8.0.1rc1"* ]]
}

@test "正式リリースを使っているときは、プレリリースだけなら成功する" {
	printf 'ZABBIX_VERSION=8.0.1\n' > "${ENV_FILE}"
	printf '8.0.0\n8.0.1\n8.0.2rc1\n' > "${TAGS_FILE}"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"up to date"* ]]
}

@test "タグを取得できない・1つも無い場合は、成功扱いにせず停止する(BR6.1)" {
	printf '8.0.0rc3\n' > "${TAGS_FILE}"
	run_check FAKE_GIT_FAIL=1
	[ "$status" -ne 0 ]
	[[ "$output" == *"取得できませんでした"* ]]

	: > "${TAGS_FILE}"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"タグが1つもありません"* ]]
}

@test "取り込み済みのバージョンが8.0系列でなければ停止する" {
	printf 'ZABBIX_VERSION=7.0.32\n' > "${ENV_FILE}"
	printf '8.0.0rc3\n' > "${TAGS_FILE}"
	run_check
	[ "$status" -ne 0 ]
}

@test "実際の .env.example から取り込み済みのバージョンを読める" {
	printf '8.0.0rc3\n' > "${TAGS_FILE}"
	cd "${REPO_ROOT}"
	run env PATH="${STUB_BIN}:${PATH}" bash scripts/check-zabbix-version.sh
	[[ "$output" == *"取り込み済み="* ]]
}
