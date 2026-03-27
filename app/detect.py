# figures out what hardware we're running on
# reads a bunch of /proc and /sys stuff and runs ip commands
import subprocess
import shlex
import re
import os
import json
from pathlib import Path


def _run(cmd: str) -> str:
    """runs a command the safe way (no shell). uses shlex to split it."""
    try:
        return subprocess.check_output(
            shlex.split(cmd), stderr=subprocess.DEVNULL, text=True
        ).strip()
    except Exception:
        return ""


def _run_shell(cmd: str) -> str:
    """runs with shell=True. only for hardcoded piped commands, never user input."""
    try:
        return subprocess.check_output(
            cmd, shell=True, stderr=subprocess.DEVNULL, text=True
        ).strip()
    except Exception:
        return ""


def detect_pi_model() -> dict:
    """checks which pi model this is by poking at /proc files"""
    model_raw = ""
    try:
        model_raw = Path("/proc/device-tree/model").read_text().strip().rstrip("\x00")
    except Exception:
        pass

    if not model_raw:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("Model"):
                model_raw = line.split(":", 1)[-1].strip()
                break

    # theres probably more but these are the ones people actually use
    model_map = {
        "Pi 5": "pi5",
        "Pi 4": "pi4",
        "Pi 3 Model B Plus": "pi3bplus",
        "Pi 3 Model B": "pi3b",
        "Pi 3": "pi3",
        "Pi Zero 2": "pizero2",
        "Pi Zero": "pizero",
    }
    model_key = "unknown"
    for name, key in model_map.items():
        if name in model_raw:
            model_key = key
            break

    mem_kb = 0
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemTotal"):
            mem_kb = int(line.split()[1])
            break
    mem_gb = round(mem_kb / 1024 / 1024, 1)

    return {
        "model_raw": model_raw or "Unknown",
        "model_key": model_key,
        "ram_gb": mem_gb,
        "arch": _run("uname -m"),
    }


def detect_interfaces() -> list[dict]:
    """finds network interfaces. skips loopback obviously."""
    interfaces = []
    ip_output = _run("ip -j link show")
    try:
        links = json.loads(ip_output)
    except Exception:
        return []

    for link in links:
        name = link.get("ifname", "")
        if name == "lo":
            continue

        flags = link.get("flags", [])
        state = link.get("operstate", "UNKNOWN")
        mac = link.get("address", "")

        # guess the type from the name, its not perfect but good enough
        iface_type = "ethernet"
        if name.startswith("wlan") or name.startswith("wl"):
            iface_type = "wifi"
        elif name.startswith("wg"):
            iface_type = "wireguard"
        elif name.startswith("tun") or name.startswith("tap"):
            iface_type = "tunnel"
        elif name.startswith("usb") or name.startswith("enx"):
            iface_type = "usb-ethernet"

        # grab the ip with regex instead of piping through grep like before
        ip_out = _run(f"ip -4 addr show {name}")
        ip_match = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", ip_out)
        ip = ip_match.group(1) if ip_match else None

        interfaces.append({
            "name": name,
            "type": iface_type,
            "state": state,
            "mac": mac,
            "ip": ip,
            "up": "UP" in flags,
        })

    # whichever interface has the default route is probably the wan
    route_output = _run("ip route show default")
    default_match = re.search(r"default\s+\S+\s+\S+\s+\S+\s+(\S+)", route_output)
    default_iface = default_match.group(1) if default_match else ""

    for iface in interfaces:
        iface["wan_candidate"] = (iface["name"] == default_iface)
        iface["lan_candidate"] = (
            not iface["wan_candidate"]
            and iface["type"] in ("ethernet", "usb-ethernet")
            and iface["name"] != default_iface
        )

    return interfaces


def detect_storage() -> dict:
    """figures out if youre booting from sd, usb ssd, nvme, whatever"""
    root_dev = _run("findmnt -n -o SOURCE /")
    storage_type = "unknown"

    if "mmcblk" in root_dev:
        storage_type = "sd"
    elif "nvme" in root_dev:
        storage_type = "nvme"
    elif any(x in root_dev for x in ("sda", "sdb", "sdc", "uda")):
        dev_name = re.sub(r'\d+$', '', root_dev.replace("/dev/", ""))
        usb_check = _run(f"udevadm info --query=property --name={dev_name}")
        storage_type = "ssd-usb" if "usb" in usb_check.lower() else "ssd-sata"

    disk_info = _run(f"lsblk -bno SIZE {root_dev}")
    # lsblk sometimes returns multiple lines for reasons
    first_line = disk_info.splitlines()[0] if disk_info.splitlines() else ""
    try:
        size_gb = round(int(first_line) / 1024 ** 3, 1)
    except Exception:
        size_gb = 0

    return {
        "root_device": root_dev,
        "type": storage_type,
        "size_gb": size_gb,
    }


def detect_os() -> dict:
    """gets os name and version. the shell=True is fine here its all hardcoded."""
    os_id = _run_shell("lsb_release -si 2>/dev/null || . /etc/os-release && echo $ID")
    os_ver = _run_shell("lsb_release -sr 2>/dev/null || . /etc/os-release && echo $VERSION_ID")
    os_codename = _run_shell("lsb_release -sc 2>/dev/null || . /etc/os-release && echo $VERSION_CODENAME")
    return {
        "id": os_id,
        "version": os_ver,
        "codename": os_codename,
        "kernel": _run("uname -r"),
    }


def detect_installed_services() -> dict:
    """checks if our stuff is actually running or not"""
    services = {
        "pihole": _run("systemctl is-active pihole-FTL"),
        "unbound": _run("systemctl is-active unbound"),
        "dnscrypt": _run("systemctl is-active dnscrypt-proxy"),
        "wireguard": _run("systemctl is-active wg-quick@wg0"),
        "nginx": _run("systemctl is-active nginx"),
        "fail2ban": _run("systemctl is-active fail2ban"),
        "grafana": _run("systemctl is-active grafana-server"),
    }
    return {k: (v == "active") for k, v in services.items()}


def full_detect() -> dict:
    """runs all the detection stuff and smashes it into one dict"""
    return {
        "pi": detect_pi_model(),
        "interfaces": detect_interfaces(),
        "storage": detect_storage(),
        "os": detect_os(),
        "installed": detect_installed_services(),
    }
