"""Zabbixのバージョン文字列(8.0.0alpha1・8.0.0beta2・8.0.0rc3・8.0.0・8.0.1 …)の解釈と比較。

このプロジェクトは 8.0 系列だけを対象にする(SUPPORTED_LINE)。8.0.0 の正式リリース前は
alpha/beta/rc のプレリリースを取り込み、その後は 8.0.x のポイントリリースへ追従する。
上流のタグは `8.0.0rc3` のように区切りなしでプレリリース種別を付けるので、その形式をそのまま扱う。

並び順は Zabbix 自身の規則と同じ: 同じ X.Y.Z の中では alpha < beta < rc < 正式リリース。
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable, Optional

# このリポジトリが追従する系列。これ以外の系列(7.4・8.2 など)へは上げない。
SUPPORTED_LINE = "8.0"

VERSION_PATTERN = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:(alpha|beta|rc)(\d+))?$")
# タグ・ファイル名に埋め込むときの検証用(アンカーなし)。
VERSION_REGEX = r"\d+\.\d+\.\d+(?:(?:alpha|beta|rc)\d+)?"

_STAGE_ORDER = {"alpha": 0, "beta": 1, "rc": 2, None: 3}


@dataclass(frozen=True, order=False)
class ZabbixVersion:
    major: int
    minor: int
    patch: int
    stage: Optional[str] = None  # "alpha" / "beta" / "rc"、正式リリースは None
    stage_number: int = 0

    @classmethod
    def parse(cls, text: str) -> "ZabbixVersion":
        m = VERSION_PATTERN.match(text or "")
        if not m:
            raise ValueError(
                f"Zabbixのバージョンは X.Y.Z または X.Y.Z(alpha|beta|rc)N の形式でなければなりません"
                f"(例: 8.0.0rc3, 8.0.1): {text!r}"
            )
        major, minor, patch, stage, number = m.groups()
        return cls(int(major), int(minor), int(patch), stage, int(number) if number else 0)

    @property
    def line(self) -> str:
        return f"{self.major}.{self.minor}"

    @property
    def is_prerelease(self) -> bool:
        return self.stage is not None

    def sort_key(self) -> tuple:
        return (self.major, self.minor, self.patch, _STAGE_ORDER[self.stage], self.stage_number)

    def __lt__(self, other: "ZabbixVersion") -> bool:
        return self.sort_key() < other.sort_key()

    def __le__(self, other: "ZabbixVersion") -> bool:
        return self.sort_key() <= other.sort_key()

    def __gt__(self, other: "ZabbixVersion") -> bool:
        return self.sort_key() > other.sort_key()

    def __ge__(self, other: "ZabbixVersion") -> bool:
        return self.sort_key() >= other.sort_key()

    def __str__(self) -> str:
        suffix = f"{self.stage}{self.stage_number}" if self.stage else ""
        return f"{self.major}.{self.minor}.{self.patch}{suffix}"


def parse_supported(text: str, line: str = SUPPORTED_LINE) -> ZabbixVersion:
    """`text` を解釈し、追従対象の系列(既定 8.0)に属さなければ ValueError にする。"""
    version = ZabbixVersion.parse(text)
    if version.line != line:
        raise ValueError(f"このリポジトリは Zabbix {line} 系列のみを対象にします: {text!r}")
    return version


def latest(candidates: Iterable[str], line: str = SUPPORTED_LINE, include_prereleases: bool = True) -> Optional[ZabbixVersion]:
    """候補(上流のタグ名など)のうち、系列 `line` で最も新しいバージョンを返す。

    解釈できない名前(`8.0.0rc3-test` のような内部タグ、別系列のタグ)は無視する。
    """
    best: Optional[ZabbixVersion] = None
    for name in candidates:
        try:
            version = ZabbixVersion.parse(name.strip())
        except ValueError:
            continue
        if version.line != line:
            continue
        if version.is_prerelease and not include_prereleases:
            continue
        if best is None or version > best:
            best = version
    return best


def upstream_update(current: str, candidates: Iterable[str], line: str = SUPPORTED_LINE) -> Optional[ZabbixVersion]:
    """`current` より新しい上流バージョンがあればそれ(系列内で最新のもの)を返し、無ければ None。

    - 現在より新しい正式リリースがあれば、それを最優先にする(rc を使っている間に 8.0.0 が出たら、
      その後に 8.0.1rc1 が出ていても、まず 8.0.0 へ移る)。
    - 現在が正式リリース(8.0.0 以降)なら、より新しいプレリリース(例: 8.0.2rc1)は追従の対象に
      しない。正式リリースを使う運用に、検証中のバージョンを持ち込まないため。
    - 現在がプレリリースで、新しい正式リリースがまだ無い間は、次のプレリリースへ追従する。
    """
    names = list(candidates)
    cur = parse_supported(current, line)
    newest_release = latest(names, line, include_prereleases=False)
    if newest_release is not None and newest_release > cur:
        return newest_release
    if cur.is_prerelease:
        newest = latest(names, line, include_prereleases=True)
        if newest is not None and newest > cur:
            return newest
    return None


DEFAULT_CDN_BASE = "https://cdn.zabbix.com/zabbix/sources"


def cdn_tarball_urls(version: str, base: str = DEFAULT_CDN_BASE) -> list[str]:
    """公式配布元(cdn.zabbix.com)上の、このバージョンのソースtarballの候補URL。

    正式リリースは sources/stable/<line>/、プレリリースは sources/development/<line>/ に置かれる。
    rc の一部(例: 8.0.0rc3)はCDNに置かれず、git のタグにしか無いことがある。その場合は
    scripts/import-upstream.sh がタグから `make dist` で同じ形のtarballを作る。
    """
    v = parse_supported(version)
    base = base.rstrip("/")
    name = f"zabbix-{v}.tar.gz"
    if v.is_prerelease:
        return [f"{base}/development/{v.line}/{name}"]
    return [f"{base}/stable/{v.line}/{name}", f"{base}/oldstable/{v.line}/{name}"]
