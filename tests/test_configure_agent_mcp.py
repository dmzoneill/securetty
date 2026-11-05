"""Behaviour tests for configure_agent_mcp.py's optional pyyaml handling."""

from conftest import load_script


def _cfg(request):
    """Load the script with HOME pointing at tmp_path."""
    tmp_path = request.getfixturevalue("tmp_path")
    monkeypatch = request.getfixturevalue("monkeypatch")
    monkeypatch.setenv("HOME", str(tmp_path))
    return load_script("scripts/configure_agent_mcp.py", "configure_agent_mcp")


def test_yaml_configs_written(request, tmp_path, func, config):
    """With pyyaml available the YAML configs are written."""
    cfg = _cfg(request)
    getattr(cfg, func)()
    assert "securetty-mcp-gateway" in (tmp_path / config).read_text(encoding="utf-8")


def test_yaml_configs_skipped_without_pyyaml(
    request,
    tmp_path,
    monkeypatch,
    capsys,
    agent,
):
    """Without pyyaml each YAML agent prints SKIP and writes nothing."""
    cfg = _cfg(request)
    monkeypatch.setattr(cfg, "yaml", None)
    getattr(cfg, f"configure_{agent}")()
    assert capsys.readouterr().err == f"SKIP: {agent} (pyyaml not installed)\n"
    assert not (tmp_path / ".config").exists()
    assert not (tmp_path / ".aider").exists()


PARAMETRIZE = {
    "test_yaml_configs_written": (
        ("func", "config"),
        [
            ("configure_goose", ".config/goose/config.yaml"),
            ("configure_aider", ".aider/config.yml"),
        ],
    ),
    "test_yaml_configs_skipped_without_pyyaml": ("agent", ["goose", "aider"]),
}


def pytest_generate_tests(metafunc):
    """Parametrize the tests listed in PARAMETRIZE."""
    if metafunc.function.__name__ in PARAMETRIZE:
        metafunc.parametrize(*PARAMETRIZE[metafunc.function.__name__])
