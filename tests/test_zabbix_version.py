"""release_tools.zabbix_version(8.0系列のバージョンの解釈・順序・追従先の判定)のテスト。

import-upstream: keep-versions(例のバージョンは固定。上流の取り込みで書き換えない)
"""
import pytest

from release_tools.cli import main
from release_tools.tagging import generate_release_tag, generate_tag, is_floating_tag
from release_tools.zabbix_version import ZabbixVersion, cdn_tarball_urls, latest, parse_supported, upstream_update


@pytest.mark.parametrize(
    "text, stage, number",
    [("8.0.0alpha1", "alpha", 1), ("8.0.0beta2", "beta", 2), ("8.0.0rc3", "rc", 3), ("8.0.0", None, 0), ("8.0.12", None, 0)],
)
def test_parse_accepts_releases_and_prereleases(text, stage, number):
    version = ZabbixVersion.parse(text)
    assert (version.stage, version.stage_number) == (stage, number)
    assert str(version) == text
    assert version.is_prerelease is (stage is not None)


@pytest.mark.parametrize("text", ["", "8.0", "8.0.0-rc3", "8.0.0rc", "8.0.0RC3", "v8.0.0", "8.0.0rc3-test", "8.0.0.1"])
def test_parse_rejects_anything_else(text):
    with pytest.raises(ValueError):
        ZabbixVersion.parse(text)


def test_order_is_alpha_beta_rc_release_then_next_patch():
    ordered = ["8.0.0alpha1", "8.0.0alpha2", "8.0.0beta1", "8.0.0beta2", "8.0.0rc1", "8.0.0rc3", "8.0.0rc10",
               "8.0.0", "8.0.1rc1", "8.0.1", "8.0.2", "8.0.10"]
    parsed = [ZabbixVersion.parse(v) for v in ordered]
    assert sorted(parsed, key=ZabbixVersion.sort_key) == parsed
    assert ZabbixVersion.parse("8.0.0rc3") < ZabbixVersion.parse("8.0.0")
    assert ZabbixVersion.parse("8.0.10") > ZabbixVersion.parse("8.0.9")


def test_only_the_8_0_line_is_supported():
    assert parse_supported("8.0.0rc3").line == "8.0"
    for other in ("7.0.32", "7.4.16", "8.2.0", "9.0.0alpha1"):
        with pytest.raises(ValueError):
            parse_supported(other)


def test_latest_ignores_other_lines_and_unparsable_tags():
    tags = ["7.4.16", "8.0.0rc1", "8.0.0rc3", "8.2.0alpha1", "8.0.0rc3-internal", "trunk"]
    assert str(latest(tags)) == "8.0.0rc3"
    assert latest(tags, include_prereleases=False) is None
    assert latest([]) is None


@pytest.mark.parametrize(
    "current, tags, expected",
    [
        # 現在の rc より新しい rc へ
        ("8.0.0rc3", ["8.0.0rc3", "8.0.0rc4"], "8.0.0rc4"),
        # rc の間に正式リリースが出たら、その後に次の rc があっても正式リリースを優先する
        ("8.0.0rc3", ["8.0.0rc4", "8.0.0", "8.0.1rc1"], "8.0.0"),
        # 正式リリース同士は新しい方へ。間のプレリリースは飛ばす
        ("8.0.0", ["8.0.0", "8.0.1rc1", "8.0.1", "8.0.2rc1"], "8.0.1"),
        # 正式リリースを使っている間は、プレリリースへは移らない
        ("8.0.1", ["8.0.1", "8.0.2rc1"], None),
        # 新しいものが無い・他の系列だけ
        ("8.0.0rc3", ["8.0.0rc1", "8.0.0rc3", "7.4.16", "8.2.0alpha1"], None),
        # 正式リリースでも、より新しい正式リリースがあれば
        ("8.0.0rc3", ["8.0.3"], "8.0.3"),
    ],
)
def test_upstream_update(current, tags, expected):
    newer = upstream_update(current, tags)
    assert (str(newer) if newer else None) == expected


def test_cdn_urls_follow_the_official_layout():
    assert cdn_tarball_urls("8.0.0rc3") == [
        "https://cdn.zabbix.com/zabbix/sources/development/8.0/zabbix-8.0.0rc3.tar.gz"
    ]
    assert cdn_tarball_urls("8.0.1", "file:///mirror/") == [
        "file:///mirror/stable/8.0/zabbix-8.0.1.tar.gz",
        "file:///mirror/oldstable/8.0/zabbix-8.0.1.tar.gz",
    ]


def test_tags_carry_the_prerelease_name_and_are_never_floating():
    tag = generate_tag("zabbix-server", "8.0.0rc3", "20261031")
    assert tag == "tamacat/zabbix-server-mysql:8.0.0rc3-alpine-b20261031"
    assert not is_floating_tag(tag)
    assert generate_release_tag("8.0.0rc3", "20261031") == "agent2-8.0.0rc3-b20261031"
    with pytest.raises(ValueError):
        generate_tag("zabbix-server", "7.0.32", "20261031")
    assert is_floating_tag("tamacat/zabbix-server-mysql:8.0.0rc-alpine-b20261031")


def test_cli_upstream_update_reads_tags_from_stdin(monkeypatch, capsys):
    import io

    monkeypatch.setattr("sys.stdin", io.StringIO("8.0.0rc1\n8.0.0rc4\n7.4.16\n"))
    assert main(["zabbix-version", "--version", "8.0.0rc3", "--upstream-update"]) == 0
    assert capsys.readouterr().out.strip() == "8.0.0rc4"

    monkeypatch.setattr("sys.stdin", io.StringIO("8.0.0rc3\n"))
    assert main(["zabbix-version", "--version", "8.0.0rc3", "--upstream-update"]) == 0
    assert capsys.readouterr().out == ""

    assert main(["zabbix-version", "--version", "7.0.32"]) == 1
    assert main(["zabbix-version", "--version", "8.0.0rc3", "--field", "prerelease"]) == 0
    assert capsys.readouterr().out.strip() == "true"
