import os
import re

from ..config import settings
from ..models.deploy import Template, TemplateVariable


def parse_template_conf(template_dir: str) -> Template | None:
    """Parst eine template.conf-Datei und gibt ein Template-Objekt zurück.

    Format der template.conf:
        TEMPLATE_NAME="..."
        TEMPLATE_DESCRIPTION="..."
        TEMPLATE_DEPLOY_DIR="..."
        TEMPLATE_REQUIRES_DOCKER=true
        TEMPLATE_REQUIRES_ROUTE=true
        TEMPLATE_ROUTE_PORT=8000
        TEMPLATE_VARS=( "NAME|Beschreibung|Default|Typ|Bedingung" ... )
        TEMPLATE_COMPOSE_PROFILES=( "VAR|WERT|PROFIL" ... )
        TEMPLATE_DEFAULTS=( "VAR=WERT" ... )
        TEMPLATE_ADDITIONAL_ROUTES=( "DOMAIN_VAR|PORT" ... )
    """
    conf_path = os.path.join(template_dir, "template.conf")
    if not os.path.exists(conf_path):
        return None

    with open(conf_path, "r") as f:
        content = f.read()

    name = _extract_value(content, "TEMPLATE_NAME") or os.path.basename(template_dir)
    description = _extract_value(content, "TEMPLATE_DESCRIPTION") or ""

    # Variablen parsen
    variables = []
    vars_block = _extract_array(content, "TEMPLATE_VARS")
    for var_line in vars_block:
        parts = var_line.split("|")
        if len(parts) >= 2:
            var = TemplateVariable(
                name=parts[0],
                description=parts[1] if len(parts) > 1 else "",
                default=parts[2] if len(parts) > 2 else "",
                type=parts[3] if len(parts) > 3 else "required",
                condition=parts[4] if len(parts) > 4 else "",
            )
            variables.append(var)

    # Compose-Profile parsen
    profiles = []
    profiles_block = _extract_array(content, "TEMPLATE_COMPOSE_PROFILES")
    for profile_line in profiles_block:
        parts = profile_line.split("|")
        if len(parts) >= 3:
            profiles.append(parts[2])
    profiles = list(set(profiles))

    # Authelia-Integration prüfen
    authelia_conf = os.path.join(template_dir, "authelia.conf")
    has_authelia = os.path.exists(authelia_conf)

    return Template(
        name=name,
        description=description,
        variables=variables,
        has_authelia=has_authelia,
        profiles=profiles,
    )


def list_templates() -> list[Template]:
    """Listet alle verfügbaren Templates."""
    templates = []
    templates_dir = settings.templates_dir

    if not os.path.exists(templates_dir):
        return templates

    for entry in sorted(os.listdir(templates_dir)):
        template_dir = os.path.join(templates_dir, entry)
        if os.path.isdir(template_dir):
            template = parse_template_conf(template_dir)
            if template:
                templates.append(template)

    return templates


def _extract_value(content: str, key: str) -> str | None:
    """Extrahiert einen einfachen Wert: KEY="value"."""
    match = re.search(rf'^{key}="([^"]*)"', content, re.MULTILINE)
    return match.group(1) if match else None


def _extract_array(content: str, key: str) -> list[str]:
    """Extrahiert ein Bash-Array: KEY=( "val1" "val2" ... )."""
    # Suche nach KEY=(\n  "..." \n  "..." \n)
    pattern = rf'{key}=\(\s*(.*?)\n\)'
    match = re.search(pattern, content, re.DOTALL)
    if not match:
        return []

    block = match.group(1)
    items = re.findall(r'"([^"]*)"', block)
    return items
