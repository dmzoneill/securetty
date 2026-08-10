#!/usr/bin/env python3
"""Configure MCP servers in all AI agent config files.

Writes securetty MCP server URLs into each agent's native config format.
Run during 'make setup' via ansible prereqs task.

Supported agents: claude, codex, gemini, kiro, cline, ampcode, opencode, goose, aider
"""

import json
import os
import sys
import textwrap
from pathlib import Path

HOME = os.path.expanduser("~")

MCP_SERVERS = {
    "jira": {"type": "http", "url": "https://securetty-mcp-gateway:8801/mcp"},
    "gitlab": {"type": "http", "url": "https://securetty-mcp-gateway:8802/mcp"},
    "github": {"type": "http", "url": "https://securetty-mcp-gateway:8803/mcp"},
    "slack": {"type": "http", "url": "https://securetty-mcp-gateway:8804/mcp"},
    "wordpress": {"type": "http", "url": "https://securetty-mcp-gateway:8805/mcp"},
    "headroom": {"type": "http", "url": "http://securetty-headroom:8788/mcp"},
}

changed = []


def ensure_dir(path: Path):
    path.mkdir(parents=True, exist_ok=True)


def merge_json_mcp(path: Path, servers_key: str = "mcpServers"):
    """Merge MCP servers into a JSON config file."""
    ensure_dir(path.parent)
    try:
        data = json.loads(path.read_text()) if path.exists() else {}
    except (json.JSONDecodeError, OSError):
        data = {}

    if servers_key not in data:
        data[servers_key] = {}

    modified = False
    for name, cfg in MCP_SERVERS.items():
        if name not in data[servers_key] or data[servers_key][name].get("url") != cfg["url"]:
            data[servers_key][name] = cfg
            modified = True

    if modified:
        path.write_text(json.dumps(data, indent=2) + "\n")
        changed.append(str(path))


def configure_claude():
    merge_json_mcp(Path(HOME) / ".claude.json")


def configure_codex():
    """Codex uses TOML but also reads mcp.json in ~/.codex/"""
    path = Path(HOME) / ".codex" / "mcp.json"
    ensure_dir(path.parent)
    try:
        data = json.loads(path.read_text()) if path.exists() else {}
    except (json.JSONDecodeError, OSError):
        data = {}

    modified = False
    for name, cfg in MCP_SERVERS.items():
        if name not in data or data[name].get("url") != cfg["url"]:
            data[name] = {"type": "url", "url": cfg["url"]}
            modified = True

    if modified:
        path.write_text(json.dumps(data, indent=2) + "\n")
        changed.append(str(path))


def configure_gemini():
    merge_json_mcp(Path(HOME) / ".gemini" / "settings.json")


def configure_kiro():
    path = Path(HOME) / ".kiro" / "settings" / "mcp.json"
    ensure_dir(path.parent)
    try:
        data = json.loads(path.read_text()) if path.exists() else {}
    except (json.JSONDecodeError, OSError):
        data = {}

    if "mcpServers" not in data:
        data["mcpServers"] = {}

    modified = False
    for name, cfg in MCP_SERVERS.items():
        entry = {"url": cfg["url"], "headers": {}}
        if name not in data["mcpServers"] or data["mcpServers"][name].get("url") != cfg["url"]:
            data["mcpServers"][name] = entry
            modified = True

    if modified:
        path.write_text(json.dumps(data, indent=2) + "\n")
        changed.append(str(path))


def configure_cline():
    path = Path(HOME) / ".cline" / "mcp_settings.json"
    ensure_dir(path.parent)
    try:
        data = json.loads(path.read_text()) if path.exists() else {}
    except (json.JSONDecodeError, OSError):
        data = {}

    if "mcpServers" not in data:
        data["mcpServers"] = {}

    modified = False
    for name, cfg in MCP_SERVERS.items():
        entry = {"url": cfg["url"], "transportType": "streamableHttp", "disabled": False}
        if name not in data["mcpServers"] or data["mcpServers"][name].get("url") != cfg["url"]:
            data["mcpServers"][name] = entry
            modified = True

    if modified:
        path.write_text(json.dumps(data, indent=2) + "\n")
        changed.append(str(path))


def configure_ampcode():
    path = Path(HOME) / ".amp" / "settings.json"
    ensure_dir(path.parent)
    try:
        data = json.loads(path.read_text()) if path.exists() else {}
    except (json.JSONDecodeError, OSError):
        data = {}

    if "amp.mcpServers" not in data:
        data["amp.mcpServers"] = {}

    modified = False
    for name, cfg in MCP_SERVERS.items():
        if name not in data["amp.mcpServers"] or data["amp.mcpServers"][name].get("url") != cfg["url"]:
            data["amp.mcpServers"][name] = {"url": cfg["url"]}
            modified = True

    if modified:
        path.write_text(json.dumps(data, indent=2) + "\n")
        changed.append(str(path))


def configure_opencode():
    path = Path(HOME) / ".config" / "opencode" / "opencode.json"
    ensure_dir(path.parent)
    try:
        data = json.loads(path.read_text()) if path.exists() else {}
    except (json.JSONDecodeError, OSError):
        data = {}

    if "mcp" not in data:
        data["mcp"] = {}

    modified = False
    for name, cfg in MCP_SERVERS.items():
        entry = {"type": "remote", "url": cfg["url"]}
        if name not in data["mcp"] or data["mcp"][name].get("url") != cfg["url"]:
            data["mcp"][name] = entry
            modified = True

    if modified:
        path.write_text(json.dumps(data, indent=2) + "\n")
        changed.append(str(path))


def configure_goose():
    """Goose uses YAML config."""
    try:
        import yaml
    except ImportError:
        print("SKIP: goose (pyyaml not installed)", file=sys.stderr)
        return

    path = Path(HOME) / ".config" / "goose" / "config.yaml"
    ensure_dir(path.parent)
    try:
        data = yaml.safe_load(path.read_text()) if path.exists() else {}
    except (yaml.YAMLError, OSError):
        data = {}

    if not data:
        data = {}
    if "mcp_servers" not in data:
        data["mcp_servers"] = {}

    modified = False
    for name, cfg in MCP_SERVERS.items():
        entry = {"uri": cfg["url"], "transport": "http"}
        if name not in data["mcp_servers"] or data["mcp_servers"][name].get("uri") != cfg["url"]:
            data["mcp_servers"][name] = entry
            modified = True

    if modified:
        path.write_text(yaml.dump(data, default_flow_style=False))
        changed.append(str(path))


def configure_aider():
    """Aider uses YAML config with mcp section."""
    try:
        import yaml
    except ImportError:
        print("SKIP: aider (pyyaml not installed)", file=sys.stderr)
        return

    path = Path(HOME) / ".aider" / "config.yml"
    ensure_dir(path.parent)
    try:
        data = yaml.safe_load(path.read_text()) if path.exists() else {}
    except (yaml.YAMLError, OSError):
        data = {}

    if not data:
        data = {}
    if "mcp-servers" not in data:
        data["mcp-servers"] = []

    existing_urls = {s.get("url") for s in data["mcp-servers"] if isinstance(s, dict)}
    modified = False
    for name, cfg in MCP_SERVERS.items():
        if cfg["url"] not in existing_urls:
            data["mcp-servers"].append({"name": name, "url": cfg["url"], "transport": "http"})
            modified = True

    if modified:
        path.write_text(yaml.dump(data, default_flow_style=False))
        changed.append(str(path))


def safe_run(name, func):
    try:
        func()
    except OSError as e:
        print(f"SKIP: {name} ({e})", file=sys.stderr)


def main():
    safe_run("claude", configure_claude)
    safe_run("codex", configure_codex)
    safe_run("gemini", configure_gemini)
    safe_run("kiro", configure_kiro)
    safe_run("cline", configure_cline)
    safe_run("ampcode", configure_ampcode)
    safe_run("opencode", configure_opencode)
    safe_run("goose", configure_goose)
    safe_run("aider", configure_aider)

    if changed:
        print(f"CHANGED {len(changed)} files:")
        for f in changed:
            print(f"  {f}")
    else:
        print("OK (all configs up to date)")


if __name__ == "__main__":
    main()
