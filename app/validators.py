# checks if people are sending us garbage
# don't feel like explaining why you cant put semicolons in an interface name
import re

# if it doesnt match these you're doing something weird and i dont want to deal with it
RE_IFACE = re.compile(r"^[a-zA-Z0-9_-]{1,15}$")
RE_DOMAIN = re.compile(
    r"^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+"
    r"[a-zA-Z]{2,}$"
)
RE_TOKEN = re.compile(r"^[a-zA-Z0-9_.:/+=-]{1,256}$")
RE_TG_TOKEN = re.compile(r"^\d{1,20}:[A-Za-z0-9_-]{20,50}$")
RE_TG_CHAT_ID = re.compile(r"^-?\d{1,20}$")
RE_PORT = re.compile(r"^\d{1,5}$")

# 4k ought to be enough for anyone's wireguard config
MAX_WG_CONFIG = 4096

VALID_TOPOLOGIES = {"inline", "router_only", "ap_mode"}
VALID_DNS = {"pihole_unbound_dnscrypt", "pihole_unbound", "pihole_dnscrypt", "pihole_only", "none"}
VALID_VPN = {"mullvad", "proton", "nordvpn", "airvpn", "custom", "none"}
VALID_DDNS_PROVIDERS = {"duckdns", "noip", "dynu"}


def _is_printable_ascii(s: str) -> bool:
    return all(0x20 <= ord(c) <= 0x7E or c in "\n\r\t" for c in s)


def validate_config(config: dict) -> tuple[dict, list[str]]:
    """returns (cleaned config, list of problems). if the list isnt empty dont use the config."""
    errors = []
    clean = {}

    topology = config.get("topology")
    if topology not in VALID_TOPOLOGIES:
        errors.append(f"Invalid topology: must be one of {VALID_TOPOLOGIES}")
    clean["topology"] = topology

    wan = str(config.get("wan_iface", "") or "")
    lan = str(config.get("lan_iface", "") or "")
    if topology == "inline":
        if not wan or not RE_IFACE.match(wan):
            errors.append(f"Invalid WAN interface name: {wan!r}")
        if not lan or not RE_IFACE.match(lan):
            errors.append(f"Invalid LAN interface name: {lan!r}")
        if wan and lan and wan == lan:
            errors.append("WAN and LAN interfaces must be different")
    else:
        if wan and not RE_IFACE.match(wan):
            errors.append(f"Invalid WAN interface name: {wan!r}")
        if lan and not RE_IFACE.match(lan):
            errors.append(f"Invalid LAN interface name: {lan!r}")
    clean["wan_iface"] = wan or "eth0"
    clean["lan_iface"] = lan or "eth1"

    dns = config.get("dns", "pihole_unbound_dnscrypt")
    if dns not in VALID_DNS:
        errors.append(f"Invalid DNS config: must be one of {VALID_DNS}")
    clean["dns"] = dns

    vpn = config.get("vpn", "none")
    if vpn not in VALID_VPN:
        errors.append(f"Invalid VPN choice: must be one of {VALID_VPN}")
    clean["vpn"] = vpn

    clean["vpn_provider"] = config.get("vpn_provider", vpn)

    wg_config = str(config.get("wg_config", "") or "")
    if wg_config:
        if len(wg_config) > MAX_WG_CONFIG:
            errors.append(f"WireGuard config too large ({len(wg_config)} bytes, max {MAX_WG_CONFIG})")
        if not _is_printable_ascii(wg_config):
            errors.append("WireGuard config contains non-printable characters")
        if "[Interface]" not in wg_config or "[Peer]" not in wg_config:
            errors.append("WireGuard config must contain [Interface] and [Peer] sections")
    clean["wg_config"] = wg_config

    ddns_enabled = _to_bool(config.get("ddns_enabled", False))
    clean["ddns_enabled"] = ddns_enabled

    if ddns_enabled:
        ddns_provider = str(config.get("ddns_provider", "") or "")
        if ddns_provider not in VALID_DDNS_PROVIDERS:
            errors.append(f"Invalid DDNS provider: must be one of {VALID_DDNS_PROVIDERS}")
        clean["ddns_provider"] = ddns_provider

        ddns_domain = str(config.get("ddns_domain", "") or "")
        if not ddns_domain or not RE_DOMAIN.match(ddns_domain):
            # duckdns people just type the subdomain part, thats fine
            if not re.match(r"^[a-zA-Z0-9-]{1,63}$", ddns_domain):
                errors.append(f"Invalid DDNS domain: {ddns_domain!r}")
        clean["ddns_domain"] = ddns_domain

        ddns_token = str(config.get("ddns_token", "") or "")
        if not ddns_token or not RE_TOKEN.match(ddns_token):
            errors.append("Invalid DDNS token: contains disallowed characters or is empty")
        clean["ddns_token"] = ddns_token
    else:
        clean["ddns_provider"] = config.get("ddns_provider", "duckdns")
        clean["ddns_domain"] = config.get("ddns_domain", "")
        clean["ddns_token"] = config.get("ddns_token", "")

    for key in ("ssh_hardening", "nftables", "fail2ban", "auto_updates", "monitoring"):
        clean[key] = _to_bool(config.get(key, False))

    telegram_enabled = _to_bool(config.get("telegram_enabled", False))
    clean["telegram_enabled"] = telegram_enabled

    if telegram_enabled:
        tg_token = str(config.get("telegram_token", "") or "")
        if not tg_token or not RE_TG_TOKEN.match(tg_token):
            errors.append("Invalid Telegram bot token format (expected digits:alphanumeric)")
        clean["telegram_token"] = tg_token

        tg_chat = str(config.get("telegram_chat_id", "") or "")
        if not tg_chat or not RE_TG_CHAT_ID.match(tg_chat):
            errors.append("Invalid Telegram chat ID (expected numeric, optionally negative)")
        clean["telegram_chat_id"] = tg_chat
    else:
        clean["telegram_token"] = config.get("telegram_token", "")
        clean["telegram_chat_id"] = config.get("telegram_chat_id", "")

    return clean, errors


def _to_bool(val) -> bool:
    # js sends booleans as strings sometimes because of course it does
    if isinstance(val, bool):
        return val
    if isinstance(val, str):
        return val.lower() in ("true", "1", "yes", "on")
    return bool(val)
