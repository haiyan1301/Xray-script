"""CDN/SNI stream rendering and downlink removal; no real service is touched."""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

from test_regressions import ROOT, definitions


class CdnStreamFixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-cdn-stream-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.template = self.work / "assets/nginx/conf/modules-enabled/stream.conf"
        self.template.parent.mkdir(parents=True)
        self.template.write_text(
            (ROOT / "config/nginx/conf/modules-enabled/stream.conf").read_text()
        )
        self.output = self.work / "rendered.conf"
        self.nginx = self.work / "nginx"
        for directory in ["modules-enabled", "sites-available", "sites-enabled"]:
            (self.nginx / directory).mkdir(parents=True, exist_ok=True)
        self.config_path = self.work / "config.json"

    @staticmethod
    def config(tag="CDN", domain="", cdn="up.example.com", down="", backend="nginx"):
        return {
            "xray": {"tag": tag, "cdnBackend": backend, "path": "/test/"},
            "nginx": {"domain": domain, "cdn": cdn, "cdnDown": down},
        }

    def bash(self, config, extra="", *, transaction=False):
        prefix = (
            f"source {shlex.quote(str(ROOT / 'lib/common.sh'))}\n"
            f"source {shlex.quote(str(ROOT / 'lib/protocols.sh'))}\n"
            + definitions("core/handler.sh", "get_cdn_backend", "render_nginx_stream_config")
        )
        if transaction:
            prefix += "\n" + definitions(
                "core/handler.sh",
                "change_domain_transaction_relative_path_is_safe",
                "change_domain_transaction_dir_is_safe",
                "snapshot_change_domain_transaction_path",
                "snapshot_change_domain_script_config",
                "remove_change_domain_transaction_target",
                "restore_change_domain_transaction_target",
                "restore_change_domain_transaction",
                "cleanup_change_domain_transaction",
                "_change_domain_invalid",
                "create_change_domain_transaction",
                "rollback_change_domain_transaction",
                "handler_change_domain",
            )
        return subprocess.run(
            ["bash", "-c", prefix + "\n" + extra],
            cwd=ROOT,
            env=os.environ | {
                "SCRIPT_CONFIG": json.dumps(config),
                "SCRIPT_CONFIG_PATH": str(self.config_path),
                "CONFIG_DIR": str(self.work / "assets"),
                "NGINX_CONFIG_DIR": str(self.nginx),
                "TEST_OUTPUT": str(self.output),
                "TEST_WORK": str(self.work),
            },
            text=True, capture_output=True, timeout=20,
        )

    def render(self, config):
        result = self.bash(config, 'render_nginx_stream_config "${TEST_OUTPUT}"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.output.read_text()

    def assert_structure(self, text, expected_names):
        mapping = re.search(r"map \$ssl_preread_server_name \$tcpsni_name \{(.*?)\}", text, re.S)
        self.assertIsNotNone(mapping)
        entries = re.findall(r"^\s*([^\s]+)\s+([^\s;]+);\s*$", mapping.group(1), re.M)
        self.assertEqual(dict(entries), expected_names | {"default": "default_backend"})
        self.assertEqual(len(entries), len(expected_names) + 1)
        self.assertEqual(len(re.findall(r"^\s*listen\s+443 reuseport;", text, re.M)), 1)
        self.assertEqual(len(re.findall(r"^\s*listen\s+\[::\]:443 reuseport;", text, re.M)), 1)
        self.assertEqual(text.count("ssl_preread    on;"), 1)
        self.assertEqual(text.count("proxy_protocol on;"), 1)

    def test_pure_cdn_has_no_dependency_on_sni_domain(self):
        text = self.render(self.config())
        self.assert_structure(text, {"up.example.com": "cdn_to_nginx"})
        self.assertNotIn("example.com     nginx_to_xray_vision;", text)

    def test_both_cdn_names_map_to_shared_tls_backend(self):
        text = self.render(self.config(domain="obsolete.example.com", down="Down.Example.Net"))
        self.assert_structure(text, {
            "up.example.com": "cdn_to_nginx", "down.example.net": "cdn_to_nginx",
        })
        self.assertNotIn("obsolete.example.com", text)

    def test_sni_preserves_reality_and_cdn_destinations(self):
        text = self.render(self.config(tag="sNi", domain="Origin.Example.Com", down="unused.example.net"))
        self.assert_structure(text, {
            "origin.example.com": "nginx_to_xray_vision", "up.example.com": "cdn_to_nginx",
        })
        self.assertNotIn("unused.example.net", text)

    def test_legacy_cdn_with_no_downlink_or_backend_renders(self):
        config = self.config()
        del config["xray"]["cdnBackend"]
        del config["nginx"]["cdnDown"]
        del config["nginx"]["domain"]
        self.assert_structure(self.render(config), {"up.example.com": "cdn_to_nginx"})

    def test_case_insensitive_duplicates_fail_without_replacing_output(self):
        for config in [
            self.config(down="UP.EXAMPLE.COM"),
            self.config(tag="SNI", domain="UP.EXAMPLE.COM"),
        ]:
            with self.subTest(config=config):
                self.output.write_text("keep current configuration\n")
                result = self.bash(config, 'render_nginx_stream_config "${TEST_OUTPUT}"')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.output.read_text(), "keep current configuration\n")

    def test_invalid_names_fail_before_output_write(self):
        for field, value in [
            ("cdn", ""), ("cdn", "up.example.com; return 200;"),
            ("cdn", "up.example.com\nother.example.com"),
            ("cdnDown", "*.example.com"), ("cdnDown", "../test"),
            ("cdnDown", {"bad": "type"}),
        ]:
            with self.subTest(field=field, value=value):
                config = self.config()
                config["nginx"][field] = value
                self.output.write_text("keep current configuration\n")
                result = self.bash(config, 'render_nginx_stream_config "${TEST_OUTPUT}"')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.output.read_text(), "keep current configuration\n")

    def test_crlf_template_is_rendered_with_real_domain_mappings(self):
        self.template.write_bytes(self.template.read_text().replace("\n", "\r\n").encode())
        text = self.render(self.config(down="down.example.net"))
        self.assertNotIn(b"\r", self.output.read_bytes())
        self.assert_structure(text, {
            "up.example.com": "cdn_to_nginx", "down.example.net": "cdn_to_nginx",
        })

    def test_modes_without_nginx_stream_are_rejected(self):
        for config in [self.config(backend="xray"), self.config(tag="HY2"), self.config(tag="SNI")]:
            with self.subTest(config=config):
                result = self.bash(config, 'render_nginx_stream_config "${TEST_OUTPUT}"')
                self.assertNotEqual(result.returncode, 0)

    def prepare_removal(self):
        config = self.config(down="down.example.net")
        stream = self.render(config)
        self.config_path.write_text(json.dumps(config) + "\n")
        (self.nginx / "modules-enabled/stream.conf").write_text(stream)
        site = self.nginx / "sites-available/down.example.net.conf"
        site.write_text("# xray_script\n# original downlink site\n")
        (self.nginx / "sites-enabled/down.example.net.conf").symlink_to(site)
        return config, stream, self.config_path.read_bytes(), site.read_bytes()

    @staticmethod
    def removal_script(failure=""):
        return r'''
declare -A CONFIG_DATA=([cdn-down]='')
restart_calls=0
write_config() { printf '%s\n' "$1" >"$2"; }
handler_nginx_restart() {
    restart_calls=$((restart_calls + 1))
    [[ "''' + failure + r'''" != restart || $restart_calls -gt 1 ]]
}
''' + ({
            "render": 'render_nginx_stream_config() { return 1; }\n',
            "write": 'write_config() { return 1; }\n',
        }.get(failure, "")) + 'handler_change_domain cdnDown n y\n'

    def test_disabling_downlink_removes_stream_mapping_and_site(self):
        config, _, _, _ = self.prepare_removal()
        result = self.bash(config, self.removal_script(), transaction=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_structure((self.nginx / "modules-enabled/stream.conf").read_text(), {
            "up.example.com": "cdn_to_nginx",
        })
        self.assertFalse((self.nginx / "sites-available/down.example.net.conf").exists())
        self.assertFalse((self.nginx / "sites-enabled/down.example.net.conf").is_symlink())
        self.assertEqual(json.loads(self.config_path.read_text())["nginx"]["cdnDown"], "")
        self.assertFalse(list(self.work.glob(".change-domain.*")))

    def test_downlink_removal_failure_restores_stream_site_and_config(self):
        for failure in ["render", "write", "restart"]:
            with self.subTest(failure=failure):
                config, stream, original_config, original_site = self.prepare_removal()
                result = self.bash(config, self.removal_script(failure), transaction=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.nginx / "modules-enabled/stream.conf").read_text(), stream)
                self.assertEqual(self.config_path.read_bytes(), original_config)
                self.assertEqual((self.nginx / "sites-available/down.example.net.conf").read_bytes(), original_site)
                link = self.nginx / "sites-enabled/down.example.net.conf"
                self.assertTrue(link.is_symlink())
                self.assertEqual(link.resolve(), self.nginx / "sites-available/down.example.net.conf")
                self.assertFalse(list(self.work.glob(".change-domain.*")))
                self.assertFalse(list((self.nginx / "modules-enabled").glob("*.tmp.*")))
                link.unlink()


if __name__ == "__main__":
    unittest.main()
