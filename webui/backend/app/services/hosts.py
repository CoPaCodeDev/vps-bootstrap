from ..config import settings
from ..models.vps import VPS


def parse_hosts_file() -> list[VPS]:
    """Liest und parst /etc/vps-hosts.

    Format: IP HOSTNAME (pro Zeile, # = Kommentar)
    """
    hosts: list[VPS] = []

    try:
        with open(settings.vps_hosts_file, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                if len(parts) >= 3 and parts[2] == "unmanaged":
                    hosts.append(VPS(name=parts[1], host=parts[1], ip=parts[0], managed=False))
                elif len(parts) >= 2:
                    ip, name = parts[0], parts[1]
                    hosts.append(VPS(name=name, host=name, ip=ip))
                elif len(parts) == 1:
                    ip = parts[0]
                    hosts.append(VPS(name=ip, host=ip, ip=ip))
    except FileNotFoundError:
        pass

    return hosts


def resolve_host(name_or_ip: str) -> str | None:
    """Löst einen Hostnamen zu einer IP auf.

    Akzeptiert: IP-Adresse, Hostname, 'proxy'
    """
    if name_or_ip == "proxy":
        return settings.proxy_host

    # Prüfe ob es bereits eine IP ist
    parts = name_or_ip.split(".")
    if len(parts) == 4 and all(p.isdigit() for p in parts):
        return name_or_ip

    # Suche in Hosts-Datei
    for host in parse_hosts_file():
        if host.name == name_or_ip or host.host == name_or_ip:
            return host.ip

    return None


def get_host_name(ip: str) -> str:
    """Gibt den Hostnamen für eine IP zurück."""
    for host in parse_hosts_file():
        if host.ip == ip:
            return host.name
    return ip
