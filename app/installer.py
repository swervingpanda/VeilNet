# runs all the install scripts one at a time and tells the browser whats happening
# server-sent events seemed right, no websocket nonsense needed
import asyncio
import json
import os
from pathlib import Path
from typing import AsyncIterator

from .validators import validate_config

SCRIPTS_DIR = Path(__file__).parent.parent / "scripts"
CONFIGS_DIR = Path(__file__).parent.parent / "configs"
LOG_FILE = Path("/var/log/veilnet-install.log")


def _sse(event: str, data: dict) -> str:
    """formats one of those server-sent event strings. the double newline is required, dont remove it."""
    return f"event: {event}\ndata: {json.dumps(data)}\n\n"


async def stream_install(config: dict) -> AsyncIterator[str]:
    """kicks off the whole install. yields sse chunks as stuff happens."""
    # validate again because paranoia is a feature not a bug
    clean_config, errors = validate_config(config)
    if errors:
        yield _sse("error", {"step": "validation", "message": f"Invalid config: {'; '.join(errors)}"})
        return

    steps = _build_steps(clean_config)
    total = len(steps)

    yield _sse("start", {"total": total, "message": "Starting VeilNet installation..."})

    log_handle = None
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        log_handle = open(LOG_FILE, "w")
    except Exception:
        pass  # if we cant log we cant log, keep going

    try:
        for i, step in enumerate(steps, 1):
            yield _sse("step", {
                "index": i,
                "total": total,
                "name": step["name"],
                "description": step.get("description", ""),
            })

            env = {**os.environ, **step.get("env", {})}

            try:
                proc = await asyncio.create_subprocess_exec(
                    "/bin/bash", "-c", step["cmd"],
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.STDOUT,
                    env=env,
                )

                async for raw in proc.stdout:
                    line = raw.decode(errors="replace").rstrip()
                    if log_handle:
                        log_handle.write(line + "\n")
                        log_handle.flush()
                    if line:
                        yield _sse("output", {"line": line})

                await proc.wait()

                if proc.returncode != 0:
                    yield _sse("error", {
                        "step": step["name"],
                        "message": f"Step failed with exit code {proc.returncode}. Check /var/log/veilnet-install.log",
                    })
                    return

            except Exception as e:
                yield _sse("error", {"step": step["name"], "message": str(e)})
                return

            yield _sse("step_done", {"index": i, "name": step["name"]})
    finally:
        if log_handle:
            log_handle.close()

    yield _sse("done", {
        "message": "Installation complete!",
        "reboot_required": True,
    })


def _build_steps(config: dict) -> list[dict]:
    """turns the wizard config into a list of bash commands to run.
    basically the whole install expressed as a to-do list."""
    steps = []
    topology = config.get("topology", "router_only")
    vpn     = config.get("vpn", "none")
    dns     = config.get("dns", "pihole_unbound_dnscrypt")
    wan     = config.get("wan_iface", "eth0")
    lan     = config.get("lan_iface", "eth1")

    # always do this first, nobody wants stale packages
    steps.append({
        "name": "System update",
        "description": "Updating package lists and upgrading installed packages",
        "cmd": "apt-get update -qq && apt-get upgrade -y -qq",
    })

    steps.append({
        "name": "Core packages",
        "description": "Installing essential utilities",
        "cmd": "apt-get install -y -qq curl wget git net-tools dnsutils htop",
    })

    if config.get("auto_updates"):
        steps.append({
            "name": "Automatic security updates",
            "description": "Configuring unattended-upgrades for security patches",
            "cmd": f"bash {SCRIPTS_DIR}/hardening.sh auto_updates",
        })

    if config.get("ssh_hardening"):
        steps.append({
            "name": "SSH hardening",
            "description": "Disabling password auth, root login, changing port to 2222",
            "cmd": f"bash {SCRIPTS_DIR}/hardening.sh ssh",
        })

    # dns - install the pieces first, then wire them together
    if dns != "none":
        steps.append({
            "name": "Pi-hole",
            "description": "Installing Pi-hole ad and tracker blocker",
            "cmd": f"bash {SCRIPTS_DIR}/dns.sh pihole",
        })

    if dns in ("pihole_unbound", "pihole_unbound_dnscrypt"):
        steps.append({
            "name": "Unbound",
            "description": "Installing Unbound recursive DNS resolver",
            "cmd": f"bash {SCRIPTS_DIR}/dns.sh unbound",
        })

    if dns in ("pihole_dnscrypt", "pihole_unbound_dnscrypt"):
        steps.append({
            "name": "dnscrypt-proxy",
            "description": "Installing dnscrypt-proxy for encrypted DNS transport",
            "cmd": f"bash {SCRIPTS_DIR}/dns.sh dnscrypt",
        })

    # had to spell out every combo here because the fallthrough was wrong
    # and i spent hours debugging why pihole_only wasnt getting an upstream
    if dns == "pihole_only":
        steps.append({
            "name": "DNS wiring",
            "description": "Connecting Pi-hole → Cloudflare (1.1.1.1)",
            "cmd": f"bash {SCRIPTS_DIR}/dns.sh wire cloudflare",
        })
    elif dns == "pihole_dnscrypt":
        steps.append({
            "name": "DNS wiring",
            "description": "Connecting Pi-hole → dnscrypt-proxy",
            "cmd": f"bash {SCRIPTS_DIR}/dns.sh wire dnscrypt",
        })
    elif dns == "pihole_unbound":
        steps.append({
            "name": "DNS wiring",
            "description": "Connecting Pi-hole → Unbound",
            "cmd": f"bash {SCRIPTS_DIR}/dns.sh wire unbound",
        })
    elif dns == "pihole_unbound_dnscrypt":
        steps.append({
            "name": "DNS wiring",
            "description": "Connecting Pi-hole → dnscrypt-proxy → Unbound (full stack)",
            "cmd": f"bash {SCRIPTS_DIR}/dns.sh wire full",
        })

    if vpn != "none":
        steps.append({
            "name": "WireGuard",
            "description": f"Installing WireGuard ({config.get('vpn_provider', 'manual')})",
            "cmd": f"bash {SCRIPTS_DIR}/vpn.sh install",
            "env": {"VPN_PROVIDER": vpn},
        })

    if config.get("ddns_enabled") and config.get("ddns_provider"):
        steps.append({
            "name": "DDNS",
            "description": f"Configuring dynamic DNS ({config['ddns_provider']})",
            "cmd": f"bash {SCRIPTS_DIR}/ddns.sh",
            "env": {
                "DDNS_PROVIDER": config.get("ddns_provider", ""),
                "DDNS_TOKEN":    config.get("ddns_token", ""),
                "DDNS_DOMAIN":   config.get("ddns_domain", ""),
            },
        })

    if topology == "inline":
        steps.append({
            "name": "Inline routing",
            "description": f"Configuring NAT forwarding {lan} → {wan}",
            "cmd": f"bash {SCRIPTS_DIR}/routing.sh inline",
            "env": {"WAN_IFACE": wan, "LAN_IFACE": lan},
        })

    if config.get("nftables"):
        steps.append({
            "name": "nftables firewall",
            "description": "Configuring strict stateful firewall rules",
            "cmd": f"bash {SCRIPTS_DIR}/firewall.sh",
            "env": {
                "WAN_IFACE":    wan,
                "LAN_IFACE":    lan,
                "SSH_PORT":     "2222" if config.get("ssh_hardening") else "22",
                "VPN_ENABLED":  "1" if vpn != "none" else "0",
            },
        })

    if config.get("fail2ban"):
        steps.append({
            "name": "fail2ban",
            "description": "Installing fail2ban intrusion prevention",
            "cmd": f"bash {SCRIPTS_DIR}/hardening.sh fail2ban",
            "env": {"SSH_PORT": "2222" if config.get("ssh_hardening") else "22"},
        })

    if config.get("monitoring"):
        steps.append({
            "name": "Prometheus + Grafana",
            "description": "Installing system monitoring stack",
            "cmd": f"bash {SCRIPTS_DIR}/monitoring.sh",
        })

    if config.get("telegram_enabled"):
        steps.append({
            "name": "Telegram alerts",
            "description": "Configuring Telegram notification bot",
            "cmd": f"bash {SCRIPTS_DIR}/alerts.sh telegram",
            "env": {
                "TG_TOKEN":   config.get("telegram_token", ""),
                "TG_CHAT_ID": config.get("telegram_chat_id", ""),
            },
        })

    steps.append({
        "name": "Cleanup",
        "description": "Removing temporary files and unused packages",
        "cmd": "apt-get autoremove -y -qq && apt-get clean",
    })

    # turn ourselves off so the wizard doesnt come back after reboot
    # not using --now because that would kill the sse stream we're currently sending lol
    steps.append({
        "name": "Disable wizard",
        "description": "Disabling VeilNet setup wizard (one-time use)",
        "cmd": "systemctl disable veilnet",
    })

    return steps
