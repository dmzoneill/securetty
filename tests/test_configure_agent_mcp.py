"""Behaviour tests for configure_agent_mcp.py's optional pyyaml handling."""

import pytest
from conftest import load_script


@pytest.fixture(name="cfg")
def fixture_cfg(tmp_path, monkeypatch):
    """Load the script with HOME pointing at tmp_path."""
    monkeypatch.setenv("HOME", str(tmp_path))
    return load_script("scripts/configure_agent_mcp.py", "configure_agent_mcp")


@pytest.mark.parametrize(
    ("func", "config"),
    [
        ("configure_goose", ".config/goose/config.yaml"),
        ("configure_aider", ".aider/config.yml"),
    ],
)
def test_yaml_configs_written(cfg, tmp_path, func, config):
    """With pyyaml available the YAML configs are written."""
    getattr(cfg, func)()
    assert "securetty-mcp-gateway" in (tmp_path / config).read_text(encoding="utf-8")


@pytest.mark.parametrize("agent", ["goose", "aider"])
def test_yaml_configs_skipped_without_pyyaml(cfg, tmp_path, monkeypatch, capsys, agent):
    """Without pyyaml each YAML agent prints SKIP and writes nothing."""
    monkeypatch.setattr(cfg, "yaml", None)
    getattr(cfg, f"configure_{agent}")()
    assert capsys.readouterr().err == f"SKIP: {agent} (pyyaml not installed)\n"
    assert not (tmp_path / ".config").exists()
    assert not (tmp_path / ".aider").exists()
