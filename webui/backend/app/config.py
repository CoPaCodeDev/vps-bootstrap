from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # SSH
    ssh_user: str = "master"
    ssh_key_path: str = "/home/master/.ssh/id_ed25519"
    ssh_timeout: int = 10
    proxy_host: str = "10.10.0.1"

    # Pfade
    vps_hosts_file: str = "/etc/vps-hosts"
    traefik_conf_dir: str = "/opt/traefik/conf.d"
    traefik_compose_dir: str = "/opt/traefik"
    templates_dir: str = "/opt/vps/templates"
    authelia_config_dir: str = "/opt/authelia/config"
    vps_cli_config_dir: str = "/home/master/.config/vps-cli"

    # Netcup API
    netcup_base_url: str = "https://www.servercontrolpanel.de/scp-core"
    netcup_keycloak_base: str = "https://www.servercontrolpanel.de"
    netcup_client_id: str = "scp"
    netcup_token_file: str = "/home/master/.config/vps-cli/netcup"

    # Backend
    api_prefix: str = "/api/v1"
    debug: bool = False

    model_config = {"env_prefix": "VPS_DASHBOARD_"}


settings = Settings()
