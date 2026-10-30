#!/bin/sh
# zabbix-proxy(SQLite3) エントリポイント [FR3.2][BR5.1]。公式 zabbix/zabbix-proxy-sqlite3 イメージと
# 同じ環境変数から /etc/zabbix/zabbix_proxy.conf を生成し、zabbix_proxy をフォアグラウンドで起動する。
# zabbix-5.0-custom の同名イメージと同じ作りに揃えてある(公式と同様に、未指定または空の変数は
# Zabbix自身の既定値のままにする)。ローカルバッファはSQLite3のみ(BR5.1の例外規定)で、MySQLの
# 接続情報は一切扱わない。LogType=console で、ログはファイルではなく標準出力へ出す。
#
# 対応するもの: 下のSCALARSの表にあるスカラー値のパラメータ、Hostname/HostnameItem、
# ZBX_USE_NODE_NAME_AS_DB_NAME、TLSのパラメータ(値そのものでの指定を含む。tls_file参照)、
# ZBX_LOADMODULE、Vault(ZBX_VAULT*)、8.0のAPMコレクター(ZBX_STARTAPMCOLLECTOR・ZBX_APM*)と
# テレメトリーの送り先(ZBX_TELEMETRYPROVIDER_<N>)。
# 対応しないもの(このイメージがその機能なしでビルドされている、または用のボリュームが無い):
# Javaゲートウェイ、IPMI、ODBC、SNMPトラップ、SSH、fpingの各変数。それ以外でも、設定された
# ZBX_* のうち対応していないものは、起動時に警告を出して無視したことを必ず知らせる(例えば
# ZBX_TLSCONNECT が黙って落ちると、サーバーとの通信が暗号化されないまま動いてしまうため)。
#
# このスクリプトはrootで起動し(su-exec自体の実行にrootが必要。server/Dockerfileと同じ方針)、
# 最後にzabbixユーザーへ降格して zabbix_proxy を起動する。--user で最初から非rootで起動された
# 場合は、降格せずにそのまま起動する。

set -eu

CONFIG_FILE="/etc/zabbix/zabbix_proxy.conf"
HOME_DIR="/var/lib/zabbix"
ENC_DIR="${HOME_DIR}/enc"
INTERNAL_ENC_DIR="${HOME_DIR}/enc_internal"
NL='
'

# <公式の環境変数>:<zabbix_proxy.conf のパラメータ>(いずれも 8.0.0rc3 の zabbix_proxy が受け付ける)
SCALARS="
ZBX_PROXYMODE:ProxyMode
ZBX_LISTENIP:ListenIP
ZBX_LISTENPORT:ListenPort
ZBX_LISTENBACKLOG:ListenBacklog
ZBX_SOURCEIP:SourceIP
ZBX_DEBUGLEVEL:DebugLevel
ZBX_ENABLEREMOTECOMMANDS:EnableRemoteCommands
ZBX_LOGREMOTECOMMANDS:LogRemoteCommands
ZBX_PROXYLOCALBUFFER:ProxyLocalBuffer
ZBX_PROXYOFFLINEBUFFER:ProxyOfflineBuffer
ZBX_HEARTBEATFREQUENCY:HeartbeatFrequency
ZBX_PROXYCONFIGFREQUENCY:ProxyConfigFrequency
ZBX_DATASENDERFREQUENCY:DataSenderFrequency
ZBX_STATSALLOWEDIP:StatsAllowedIP
ZBX_STARTPREPROCESSORS:StartPreprocessors
ZBX_STARTPOLLERS:StartPollers
ZBX_STARTPOLLERSUNREACHABLE:StartPollersUnreachable
ZBX_STARTTRAPPERS:StartTrappers
ZBX_STARTPINGERS:StartPingers
ZBX_STARTDISCOVERERS:StartDiscoverers
ZBX_STARTHTTPPOLLERS:StartHTTPPollers
ZBX_STARTAGENTPOLLERS:StartAgentPollers
ZBX_STARTHTTPAGENTPOLLERS:StartHTTPAgentPollers
ZBX_STARTSNMPPOLLERS:StartSNMPPollers
ZBX_STARTBROWSERPOLLERS:StartBrowserPollers
ZBX_WEBDRIVERURL:WebDriverURL
ZBX_MAXCONCURRENTCHECKSPERPOLLER:MaxConcurrentChecksPerPoller
ZBX_PROXYBUFFERMODE:ProxyBufferMode
ZBX_PROXYMEMORYBUFFERSIZE:ProxyMemoryBufferSize
ZBX_PROXYMEMORYBUFFERAGE:ProxyMemoryBufferAge
ZBX_ALLOWUNSUPPORTEDDBVERSIONS:AllowUnsupportedDBVersions
ZBX_STARTTELEMETRYQUERYPOLLERS:StartTelemetryQueryPollers
ZBX_STARTAPMCOLLECTOR:StartAPMCollector
ZBX_APMLISTENIP:APMListenIP
ZBX_APMLISTENPORT:APMListenPort
ZBX_STARTVMWARECOLLECTORS:StartVMwareCollectors
ZBX_VMWAREFREQUENCY:VMwareFrequency
ZBX_VMWAREPERFFREQUENCY:VMwarePerfFrequency
ZBX_VMWARECACHESIZE:VMwareCacheSize
ZBX_VMWARETIMEOUT:VMwareTimeout
ZBX_HOUSEKEEPINGFREQUENCY:HousekeepingFrequency
ZBX_CACHESIZE:CacheSize
ZBX_STARTDBSYNCERS:StartDBSyncers
ZBX_HISTORYCACHESIZE:HistoryCacheSize
ZBX_HISTORYINDEXCACHESIZE:HistoryIndexCacheSize
ZBX_TIMEOUT:Timeout
ZBX_TRAPPERTIMEOUT:TrapperTimeout
ZBX_UNREACHABLEPERIOD:UnreachablePeriod
ZBX_UNAVAILABLEDELAY:UnavailableDelay
ZBX_UNREACHABLEDELAY:UnreachableDelay
ZBX_LOGSLOWQUERIES:LogSlowQueries
ZBX_TLSCONNECT:TLSConnect
ZBX_TLSLISTEN:TLSListen
ZBX_TLSACCEPT:TLSAccept
ZBX_TLSSERVERCERTISSUER:TLSServerCertIssuer
ZBX_TLSSERVERCERTSUBJECT:TLSServerCertSubject
ZBX_TLSCIPHERALL:TLSCipherAll
ZBX_TLSCIPHERALL13:TLSCipherAll13
ZBX_TLSCIPHERCERT:TLSCipherCert
ZBX_TLSCIPHERCERT13:TLSCipherCert13
ZBX_TLSCIPHERPSK:TLSCipherPSK
ZBX_TLSCIPHERPSK13:TLSCipherPSK13
ZBX_TLSPSKIDENTITY:TLSPSKIdentity
"

# <パラメータ>:<ファイルのパスを入れる変数>:<ファイルの中身そのものを入れる変数>
TLS_FILES="
TLSCAFile:ZBX_TLSCAFILE:ZBX_TLSCA
TLSCRLFile:ZBX_TLSCRLFILE:ZBX_TLSCRL
TLSCertFile:ZBX_TLSCERTFILE:ZBX_TLSCERT
TLSKeyFile:ZBX_TLSKEYFILE:ZBX_TLSKEY
TLSPSKFile:ZBX_TLSPSKFILE:ZBX_TLSPSK
APMTLSCAFile:ZBX_APMTLSCAFILE:ZBX_APMTLSCA
APMTLSCertFile:ZBX_APMTLSCERTFILE:ZBX_APMTLSCERT
APMTLSKeyFile:ZBX_APMTLSKEYFILE:ZBX_APMTLSKEY
"

# Vault(秘密のマクロ用。公式と同じく ZBX_VAULT と ZBX_VAULTURL が両方あるときだけ設定へ書く)。SQLite3の
# ローカルバッファにはDBの認証情報が無いので、VaultDBPath は扱わない。VAULT_TOKEN は zabbix_proxy が
# 環境変数から直接読む。
VAULT_SCALARS="
ZBX_VAULT:Vault
ZBX_VAULTURL:VaultURL
ZBX_VAULTPREFIX:VaultPrefix
ZBX_VAULTTLSCERTFILE:VaultTLSCertFile
ZBX_VAULTTLSKEYFILE:VaultTLSKeyFile
ZBX_VAULTAPPROLEID:VaultAppRoleID
ZBX_VAULTAPPSECRETID:VaultAppSecretID
"

# <従来の変数名>:<公式の変数名> — 公式の変数が未指定(または空)のときだけ従来の名前を使う。
# ZBX_PROXY_HOSTNAME はこのプロジェクトの6.0のイメージが以前使っていた名前(compose.ymlもこれを
# 渡す)で、公式のZBX_HOSTNAMEを読んでいなかった。ZBX_PROXYHEARTBEATFREQUENCY は5.0側の名前。
# ZBX_CONFIGFREQUENCY は6.0までの名前で、7.0のzabbix_proxyではConfigFrequencyが非推奨のため、公式の
# ZBX_PROXYCONFIGFREQUENCY(ProxyConfigFrequency)へ読み替える。
ALIASES="
ZBX_PROXY_HOSTNAME:ZBX_HOSTNAME
ZBX_PROXYHEARTBEATFREQUENCY:ZBX_HEARTBEATFREQUENCY
ZBX_CONFIGFREQUENCY:ZBX_PROXYCONFIGFREQUENCY
"

fail() {
	echo "**** ERROR: $1" >&2
	echo "**** Exiting..." >&2
	exit 1
}

zbx_env_names() {
	env | sed -n 's/^\(ZBX_[A-Za-z0-9_]*\)=.*/\1/p'
}

# conf_set <パラメータ> <値> — 値が空でなければ設定ファイルへ追記する。
conf_set() {
	[ -n "$2" ] || return 0
	case "$2" in
		*"${NL}"*) fail "the value for $1 contains a line break" ;;
	esac
	printf '%s=%s\n' "$1" "$2" >> "${CONFIG_FILE}"
}

env_value() {
	printenv "$1" || true
}

# tls_file <パラメータ> <パスの変数> <中身の変数> — 中身の変数に値があれば enc_internal 配下のファイルへ
# 書き出してそれを使い(こちらが優先)、無ければパスの変数を使う(相対パスは enc ボリューム内を探す)。
# 公式イメージと同じ。rootで書いたファイルはzabbixユーザーが読めるよう、所有者を変更する。
tls_file() {
	file="$(env_value "$2")"
	content="$(env_value "$3")"
	if [ -n "${content}" ]; then
		file="${INTERNAL_ENC_DIR}/$1"
		( umask 077 && printf '%s\n' "${content}" > "${file}" )
		if [ "$(id -u)" = "0" ]; then
			chown zabbix:zabbix "${file}"
		fi
	elif [ -n "${file}" ]; then
		case "${file}" in
			/*) ;;
			*) file="${ENC_DIR}/${file}" ;;
		esac
	fi
	conf_set "$1" "${file}"
}

# indexed_providers <変数の接頭辞> <パラメータ> — 8.0 のヒストリー/テレメトリーのプロバイダー。公式と同じく
# <接頭辞>_0, <接頭辞>_1, ... を番号順に1つずつ <パラメータ>= の行にする(例: ZBX_HISTORYPROVIDER_0 →
# HistoryProvider=)。値はZabbix自身の形式("clickhouse;url=http://...,db=zabbix,username=...")で書く。
# 公式が受けるJSONの形式と、それに付ける <接頭辞>_<N>_USERNAME / _PASSWORD 等の別変数には対応しない
# (このイメージはJSONを解釈しない)ので、黙って無視せずに起動を止める。
indexed_providers() {
	prefix="$1"
	if [ -n "$(env_value "${prefix}")" ]; then
		fail "${prefix} is not supported; use indexed variables such as ${prefix}_0"
	fi
	for name in $(zbx_env_names); do
		case "${name}" in
			"${prefix}"_*) ;;
			*) continue ;;
		esac
		index="${name#"${prefix}"_}"
		case "${index}" in
			0 | [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) ;;
			*) fail "${name}: only the native form ${prefix}_<N> is supported by this image (credentials in separate variables need the JSON form, which is not supported; put username=/password= in the value)" ;;
		esac
	done
	for index in $(zbx_env_names | grep -E "^${prefix}_[0-9]+$" | sed "s/^${prefix}_//" | sort -n); do
		value="$(env_value "${prefix}_${index}")"
		[ -n "${value}" ] || fail "${prefix}_${index} must not be empty"
		case "${value}" in
			"{"* | "["* | " {"* | " ["*) fail "${prefix}_${index}: the JSON form is not supported by this image; use the native form, e.g. clickhouse;url=http://clickhouse:8123,db=zabbix" ;;
		esac
		conf_set "$2" "${value}"
	done
}

for pair in ${ALIASES}; do
	legacy="${pair%%:*}"
	official="${pair#*:}"
	if [ -z "$(env_value "${official}")" ] && [ -n "$(env_value "${legacy}")" ]; then
		export "${official}=$(env_value "${legacy}")"
	fi
done

: "${ZBX_SERVER_HOST:=zabbix-server}"
hostname_default="zabbix-proxy-sqlite3"

# 6.0ではServerPortパラメータが非推奨(zabbix_proxyが起動のたびに警告する)で、公式のイメージも
# Server=<ホスト>:<ポート> と書く。5.0で使えるZBX_SERVER_PORTは、指定されたときだけここへ反映する。
server="${ZBX_SERVER_HOST}"
if [ -n "${ZBX_SERVER_PORT:-}" ]; then
	case "${server}" in
		*:*) echo "**** WARNING: ZBX_SERVER_PORT is ignored because ZBX_SERVER_HOST already contains a port." >&2 ;;
		*) server="${server}:${ZBX_SERVER_PORT}" ;;
	esac
fi

echo "**** Generating ${CONFIG_FILE} from environment variables..."

cat > "${CONFIG_FILE}" <<'CONF'
# Generated by docker/proxy/entrypoint.sh at container start — do not edit by hand, it is
# overwritten on every restart.

LogType=console
PidFile=/run/zabbix/zabbix_proxy.pid
SocketDir=/run/zabbix
ExternalScripts=/var/lib/zabbix/externalscripts
CONF

conf_set Server "${server}"

if [ -z "${ZBX_HOSTNAME:-}" ] && [ -n "${ZBX_HOSTNAMEITEM:-}" ]; then
	conf_set HostnameItem "${ZBX_HOSTNAMEITEM}"
else
	conf_set Hostname "${ZBX_HOSTNAME:-${hostname_default}}"
	conf_set HostnameItem "${ZBX_HOSTNAMEITEM:-}"
fi

# このコンポーネントが持つ唯一のローカルな状態(docker/proxy/Dockerfile参照): db_dataボリューム内の
# SQLiteファイル。1つのイメージから複数のプロキシを動かしても同じファイルを取り合わないよう、
# プロキシ自身のHostnameで名前を付ける(ZBX_USE_NODE_NAME_AS_DB_NAME=true ならコンテナ自身のホスト名)。
if [ "$(env_value ZBX_USE_NODE_NAME_AS_DB_NAME | tr '[:upper:]' '[:lower:]')" = "true" ]; then
	db_name="$(uname -n)"
else
	db_name="${ZBX_HOSTNAME:-${hostname_default}}"
fi
case "${db_name}" in
	*/*) fail "ZBX_HOSTNAME must not contain a '/' (it names the SQLite file)" ;;
esac
conf_set DBName "${HOME_DIR}/db_data/${db_name}.sqlite"

for pair in ${SCALARS}; do
	conf_set "${pair#*:}" "$(env_value "${pair%%:*}")"
done

for entry in ${TLS_FILES}; do
	key="${entry%%:*}"
	rest="${entry#*:}"
	tls_file "${key}" "${rest%%:*}" "${rest#*:}"
done

if [ -n "$(env_value ZBX_VAULT)" ] && [ -n "$(env_value ZBX_VAULTURL)" ]; then
	for pair in ${VAULT_SCALARS}; do
		conf_set "${pair#*:}" "$(env_value "${pair%%:*}")"
	done
else
	for pair in ${VAULT_SCALARS}; do
		name="${pair%%:*}"
		case "${name}" in ZBX_VAULT | ZBX_VAULTURL) continue ;; esac
		if [ -n "$(env_value "${name}")" ]; then
			echo "**** WARNING: ${name} is set but ZBX_VAULT and ZBX_VAULTURL are not both set; the Vault settings are ignored." >&2
		fi
	done
fi

# 8.0: APMで受けたテレメトリーの送り先(ClickHouse)。
indexed_providers ZBX_TELEMETRYPROVIDER TelemetryProvider

if [ -n "$(env_value ZBX_LOADMODULE)" ]; then
	conf_set LoadModulePath "${HOME_DIR}/modules"
	old_ifs="${IFS}"
	IFS=','
	for module in $(env_value ZBX_LOADMODULE); do
		conf_set LoadModule "${module}"
	done
	IFS="${old_ifs}"
fi

# 設定されているのにこのイメージが扱わない変数を、運用者へ知らせる。
known=" ZBX_SERVER_HOST ZBX_SERVER_PORT ZBX_HOSTNAME ZBX_HOSTNAMEITEM ZBX_USE_NODE_NAME_AS_DB_NAME ZBX_LOADMODULE ZBX_CLEAR_ENV"
for pair in ${ALIASES}; do
	known="${known} ${pair%%:*}"
done
for pair in ${SCALARS} ${VAULT_SCALARS}; do
	known="${known} ${pair%%:*}"
done
for entry in ${TLS_FILES}; do
	rest="${entry#*:}"
	known="${known} ${rest%%:*} ${rest#*:}"
done
for name in $(zbx_env_names); do
	case "${name}" in
		ZBX_TELEMETRYPROVIDER_*) continue ;;
	esac
	case "${known} " in
		*" ${name} "*) ;;
		*) echo "**** WARNING: ${name} is set but is not supported by this image; it is ignored." >&2 ;;
	esac
done

# 公式のイメージと同じく、zabbix_proxy が動く環境からZBX_*を取り除く(PSKや鍵の中身が入っている
# ことがあるため)。ZBX_CLEAR_ENV=false なら残す。
if [ "${ZBX_CLEAR_ENV:-true}" != "false" ]; then
	for name in $(zbx_env_names); do
		unset "${name}"
	done
fi

echo "**** Starting Zabbix proxy..."
if [ "$(id -u)" = "0" ]; then
	exec su-exec zabbix zabbix_proxy --foreground -c "${CONFIG_FILE}"
fi
exec zabbix_proxy --foreground -c "${CONFIG_FILE}"
