#!/usr/bin/env python3
"""Securetty credential proxy — serves git credentials and CLI tokens.
Runs in its own container with ONLY git-related secrets.
Agent containers call this to get credentials on demand."""

import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

TOKEN_MAP = {
    "github.com": {"username": "x-access-token", "token_var": "GITHUB_TOKEN"},
    "gitlab.cee.redhat.com": {"username": "oauth2", "token_var": "GITLAB_TOKEN"},
}

TOKEN_ALIASES = {
    "github": "GITHUB_TOKEN",
    "gitlab": "GITLAB_TOKEN",
}

CONFIG_FILE = os.environ.get("CREDS_CONFIG", "/config/credentials.json")


def load_token_map():
    """Load per-org credential mapping from JSON config, merged with defaults."""
    config_map = dict(TOKEN_MAP)  # start with defaults
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            cfg = json.load(f)
        for entry in cfg.get("credentials", []):
            host = entry.get("host", "")
            config_map[host] = {
                "username": entry.get("username", "oauth2"),
                "token_var": entry.get("token_var", ""),
            }
        for alias_name, var in cfg.get("token_aliases", {}).items():
            TOKEN_ALIASES[alias_name] = var
    return config_map


class CredentialHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # silent

    def do_GET(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)

        if parsed.path == "/credential":
            host = params.get("host", [""])[0]
            protocol = params.get("protocol", ["https"])[0]
            token_map = load_token_map()
            entry = token_map.get(host)
            if entry:
                token = os.environ.get(entry["token_var"], "")
                if token:
                    body = f"protocol={protocol}\nhost={host}\nusername={entry['username']}\npassword={token}\n"
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain")
                    self.end_headers()
                    self.wfile.write(body.encode())
                    return
            self.send_response(404)
            self.end_headers()

        elif parsed.path.startswith("/token/"):
            name = parsed.path.split("/")[-1]
            var = TOKEN_ALIASES.get(name)
            if var:
                token = os.environ.get(var, "")
                if token:
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain")
                    self.end_headers()
                    self.wfile.write(token.encode())
                    return
            self.send_response(404)
            self.end_headers()

        elif parsed.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")

        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8800"))
    server = HTTPServer(("0.0.0.0", port), CredentialHandler)
    print(f"Credential proxy listening on :{port}")
    server.serve_forever()
