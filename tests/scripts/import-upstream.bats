#!/usr/bin/env bats
# scripts/import-upstream.sh のテスト。
#
# import-upstream: keep-versions(例のバージョンは固定。上流の取り込みで書き換えない)
#
# 一時ディレクトリに小さなリポジトリを作り(パッチを当てた sources/zabbix-8.0.0rc3 を持つ)、
# file:// の偽のCDNから 8.0.0rc4 を取り込ませる。ネットワークもdockerも使わない(--source cdn)。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	T="$(mktemp -d)"
	R="${T}/repo"
	CDN="${T}/cdn"
	mkdir -p "${R}/scripts" "${R}/data" "${CDN}/development/8.0"
	cp -r "${REPO_ROOT}/release_tools" "${R}/"
	cp "${REPO_ROOT}/scripts/import-upstream.sh" "${R}/scripts/"
	printf 'ZABBIX_SRC_DIR=sources/zabbix-8.0.0rc3\nZABBIX_VERSION=8.0.0rc3\n' > "${R}/.env.example"
	printf 'Built from 8.0.0rc3. Not 8.0.0rc31, not 18.0.0rc3.\n' > "${R}/README.md"
	printf '# import-upstream: keep-versions\nexample=8.0.0rc3\n' > "${R}/keep.txt"
	# 本物のリポジトリと同じく、Pythonのキャッシュは追跡しない(無いと作業ツリーが汚れて見える)
	printf '__pycache__/\n' > "${R}/.gitignore"
	rm -rf "${R}/release_tools/__pycache__"

	cd "${R}"
	git init -q -b main .
	git config user.email test@example.invalid
	git config user.name test
	git config core.fileMode false

	# 無改変の取り込み → upstream-import-ref → このプロジェクトのパッチ、の順の履歴
	mkdir -p sources/zabbix-8.0.0rc3/src
	printf 'line1\nline2\nline3\nline4\nline5\nline6\n' > sources/zabbix-8.0.0rc3/src/a.c
	printf 'only in rc3\n' > sources/zabbix-8.0.0rc3/src/old.c
	git add -A && git commit -q -m "upstream: import Zabbix 8.0.0rc3 (unmodified)"
	git rev-parse HEAD > data/upstream-import-ref
	git add -A && git commit -q -m "set import ref"
	printf 'line1\nline2\nline3\nline4\nline5\nline6 patched by us\n' > sources/zabbix-8.0.0rc3/src/a.c
	git add -A && git commit -q -m "patch a.c"

	# 偽のCDN: 8.0.0rc4 のtarball(a.c の1行目が上流で変わり、old.c が消え、実行ファイルが増える)
	mkdir -p "${T}/tree/zabbix-8.0.0rc4/src" "${T}/tree/zabbix-8.0.0rc4/bin"
	printf 'line1 changed upstream\nline2\nline3\nline4\nline5\nline6\n' > "${T}/tree/zabbix-8.0.0rc4/src/a.c"
	printf '#!/bin/sh\n' > "${T}/tree/zabbix-8.0.0rc4/bin/run.sh"
	chmod 755 "${T}/tree/zabbix-8.0.0rc4/bin/run.sh"
	tar -czf "${CDN}/development/8.0/zabbix-8.0.0rc4.tar.gz" -C "${T}/tree" zabbix-8.0.0rc4
	# 公式の .sha256 はハッシュだけの1行
	sha256sum "${CDN}/development/8.0/zabbix-8.0.0rc4.tar.gz" | awk '{print $1}' > "${CDN}/development/8.0/zabbix-8.0.0rc4.tar.gz.sha256"
}

teardown() {
	rm -rf "${T}"
}

run_import() {
	run env ZBX_CDN_BASE="file://${CDN}" bash scripts/import-upstream.sh "$@"
}

@test "無改変のツリーだけを1コミットにし、旧ツリーを消して、パッチを当て直し、バージョン表記と取り込み基準を更新する" {
	before="$(git rev-parse HEAD)"
	run_import --source cdn 8.0.0rc4
	[ "$status" -eq 0 ]

	# 1コミットだけ増え、それは無改変の取り込み(旧ツリーの削除を含む)
	[ "$(git rev-list --count "${before}..HEAD")" -eq 1 ]
	[ "$(git log -1 --format=%s)" = "upstream: import Zabbix 8.0.0rc4 (unmodified)" ]
	git log -1 --format=%B | grep -q "SHA-256: "
	[ "$(git show HEAD:sources/zabbix-8.0.0rc4/src/a.c | tail -n 1)" = "line6" ]
	! git cat-file -e HEAD:sources/zabbix-8.0.0rc3 2>/dev/null
	[ ! -e sources/zabbix-8.0.0rc3 ]

	# tarballの実行ビットがそのまま記録される(core.fileMode=false でも)
	[ "$(git ls-files -s sources/zabbix-8.0.0rc4/bin/run.sh | cut -c1-6)" = "100755" ]
	[ "$(git ls-files -s sources/zabbix-8.0.0rc4/src/a.c | cut -c1-6)" = "100644" ]

	# パッチは作業ツリーへ当て直される(上流の変更とこちらの変更の両方が残る)
	[ "$(head -n 1 sources/zabbix-8.0.0rc4/src/a.c)" = "line1 changed upstream" ]
	[ "$(tail -n 1 sources/zabbix-8.0.0rc4/src/a.c)" = "line6 patched by us" ]
	[[ "$output" != *"did not apply cleanly"* ]]

	# バージョン表記と取り込み基準(コミットはしない)
	[ "$(cat data/upstream-import-ref)" = "$(git rev-parse HEAD)" ]
	grep -qx "ZABBIX_VERSION=8.0.0rc4" .env.example
	grep -qx "ZABBIX_SRC_DIR=sources/zabbix-8.0.0rc4" .env.example
	[ "$(cat README.md)" = "Built from 8.0.0rc4. Not 8.0.0rc31, not 18.0.0rc3." ]
	grep -qx "example=8.0.0rc3" keep.txt
	[[ "$output" == *"Imported Zabbix 8.0.0rc4 (was 8.0.0rc3)"* ]]
}

@test "パッチが当たらない場合は、取り込みのコミットは残し、衝突を知らせる" {
	printf 'totally different\n' > "${T}/tree/zabbix-8.0.0rc4/src/a.c"
	tar -czf "${CDN}/development/8.0/zabbix-8.0.0rc4.tar.gz" -C "${T}/tree" zabbix-8.0.0rc4
	sha256sum "${CDN}/development/8.0/zabbix-8.0.0rc4.tar.gz" | awk '{print $1}' > "${CDN}/development/8.0/zabbix-8.0.0rc4.tar.gz.sha256"

	run_import --source cdn 8.0.0rc4
	[ "$status" -eq 0 ]
	[ "$(git log -1 --format=%s)" = "upstream: import Zabbix 8.0.0rc4 (unmodified)" ]
	[[ "$output" == *"did not apply cleanly"* ]]
}

@test "チェックサムが合わなければ、何もコミットせずに停止する(gitのタグへ切り替えない)" {
	echo "0000000000000000000000000000000000000000000000000000000000000000" > "${CDN}/development/8.0/zabbix-8.0.0rc4.tar.gz.sha256"
	before="$(git rev-parse HEAD)"
	run_import 8.0.0rc4
	[ "$status" -ne 0 ]
	[[ "$output" == *"SHA-256 mismatch"* ]]
	[ "$(git rev-parse HEAD)" = "${before}" ]
	[ -z "$(git status --porcelain)" ]
}

@test ".sha256 の無いtarballは使わない" {
	rm "${CDN}/development/8.0/zabbix-8.0.0rc4.tar.gz.sha256"
	run_import --source cdn 8.0.0rc4
	[ "$status" -ne 0 ]
	[[ "$output" == *"refusing an unverified tarball"* ]]
}

@test "--source cdn でCDNにtarballが無ければ停止する(gitのタグからは作らない)" {
	run_import --source cdn 8.0.0rc5
	[ "$status" -ne 0 ]
	[[ "$output" == *"no official tarball for 8.0.0rc5"* ]]
}

@test "8.0系列以外・取り込み済みと同じバージョン・作業ツリーが汚れている場合は停止する" {
	run_import --source cdn 7.4.16
	[ "$status" -ne 0 ]
	[[ "$output" == *"is not a Zabbix 8.0 version"* ]]

	run_import --source cdn 8.0.0rc3
	[ "$status" -ne 0 ]
	[[ "$output" == *"already the current version"* ]]

	echo dirty >> README.md
	run_import --source cdn 8.0.0rc4
	[ "$status" -ne 0 ]
	[[ "$output" == *"not clean"* ]]
}
