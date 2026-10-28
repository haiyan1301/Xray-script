"""Offline regression checks. Never install software or change host services."""

import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / "tests/fixtures/upstream-install-release.sh"


def definitions(path, *names):
    """Load named top-level functions without running a service entry point."""
    source = (ROOT / path).read_text()
    result = []
    for name in names:
        match = re.search(
            rf"^function {re.escape(name)}\(\) [{{(]\n.*?^[}})]$",
            source,
            re.MULTILINE | re.DOTALL,
        )
        if not match:
            raise AssertionError(f"Missing function {path}:{name}")
        result.append(match.group())
    return "\n".join(result)


class RegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-regression-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.config = self.work / "config.json"
        self.runtime = self.work / "runtime.json"
        self.binary = self.work / "bin/xray"
        self.marker = self.work / "executed"
        config = json.loads((ROOT / "config.json").read_text())
        config["language"] = "en"
        config["xray"].update(version="v1.8.24", githubProxy="n")
        self.config.write_text(json.dumps(config) + "\n")
        self.initial_config = self.config.read_bytes()
        self.env = os.environ.copy()
        self.env.update(
            SCRIPT_CONFIG_PATH_OVERRIDE=str(self.config),
            XRAY_CONFIG_PATH_OVERRIDE=str(self.runtime),
            XRAY_BIN_PATH_OVERRIDE=str(self.binary),
            TEST_WORK=str(self.work),
            TEST_MARKER=str(self.marker),
            TEST_UPSTREAM=str(UPSTREAM),
            TEST_REPO=str(ROOT),
        )

    def bash(self, body, *, handler=True, success=True, stdin=None, env=None):
        prefix = ""
        if handler:
            prefix = (
                f"source {shlex.quote(str(ROOT / 'core/handler.sh'))}\n"
                "sync() { :; }\nsystemctl() { [[ \"$*\" != *is-active* ]] || return 3; return 1; }\nload_i18n\n"
            )
        result = subprocess.run(
            ["bash", "-c", prefix + body],
            env=self.env | (env or {}),
            cwd=ROOT,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=20,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def old_binary(self):
        self.binary.parent.mkdir(parents=True, exist_ok=True)
        self.binary.write_text("#!/usr/bin/env bash\nprintf 'Xray 1.8.24 old\\n'\n")
        self.binary.chmod(0o755)
        return self.binary.read_bytes()

    def mock_installer(self):
        # Use the pinned upstream's real parser, bypassing only host mutations.
        installer = self.work / "mock-installer.sh"
        installer.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            "source <(sed '$d' \"${TEST_UPSTREAM}\")\n"
            "judgment_parameters \"$@\"\n"
            "[[ $INSTALL == 1 && -n $SPECIFIED_VERSION ]]\n"
            "[[ $(jq -r .xray.version \"${SCRIPT_CONFIG_PATH_OVERRIDE}\") == v1.8.24 ]]\n"
            "printf '%s\\n' \"$@\" >\"${TEST_WORK}/installer-args\"\n"
            "version=${SPECIFIED_VERSION#v}\n"
            "[[ ${TEST_INSTALL_MODE:-ok} != mismatch ]] || version=0.0.0\n"
            "printf '#!/usr/bin/env bash\\nprintf \\\"Xray %s test\\\\n\\\"\\n' \"$version\" >\"${XRAY_BIN_PATH_OVERRIDE}\"\n"
            "chmod 755 \"${XRAY_BIN_PATH_OVERRIDE}\"\n"
            "[[ ${TEST_INSTALL_MODE:-ok} != fail ]] || exit 23\n"
        )
        self.env["TEST_INSTALLER"] = str(installer)
        return """
ensure_service_users() { return 0; }
fetch_xray_install_script() { cat "${TEST_INSTALLER}"; }
curl() {
    if [[ "$*" == *releases/latest* ]]; then
        printf '%s\n' '{"tag_name":"v26.9.13"}'
    else
        printf '%s\n' '[{"tag_name":"v26.9.13","draft":false,"prerelease":true}]'
    fi
}
"""

    def test_original_arguments_reproduce_reported_error(self):
        result = self.bash(
            'source <(sed \'$d\' "${TEST_UPSTREAM}"); '
            'judgment_parameters install -u xray --version v26.9.13',
            handler=False,
            success=False,
        )
        self.assertIn("unknown option -- -", result.stdout)

    def test_latest_install_uses_supported_arguments_and_commits(self):
        self.bash(self.mock_installer() + "handler_install latest y")
        config = json.loads(self.config.read_text())
        self.assertEqual(config["xray"]["version"], "v26.9.13")
        self.assertEqual(
            (self.work / "installer-args").read_text().splitlines(),
            ["install", "--version", "v26.9.13"],
        )
        self.assertFalse(list(self.binary.parent.glob(".xray-install.*")))
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)

    def test_full_install_with_resolved_version(self):
        self.bash(self.mock_installer() + "handler_install v26.9.13 y y")
        self.assertEqual(json.loads(self.config.read_text())["xray"]["version"], "v26.9.13")

    def test_specific_version_does_not_resolve_to_latest_release(self):
        self.bash(self.mock_installer() + "handler_install 25.12.8 y")
        self.assertEqual(json.loads(self.config.read_text())["xray"]["version"], "v25.12.8")

    def test_install_failure_preserves_binary_and_metadata_for_all_entrypoints(self):
        for arguments in ["latest y", "release y", "v26.9.13 y y"]:
            with self.subTest(arguments=arguments):
                self.config.write_bytes(self.initial_config)
                old_binary = self.old_binary()
                self.bash(
                    self.mock_installer() + "handler_install " + arguments,
                    success=False,
                    env={"TEST_INSTALL_MODE": "fail"},
                )
                self.assertEqual(self.config.read_bytes(), self.initial_config)
                self.assertEqual(self.binary.read_bytes(), old_binary)
                self.assertFalse(list(self.work.glob("config.json.version.*")))
                self.assertFalse(list(self.binary.parent.glob(".xray-install.*")))

    def test_version_mismatch_restores_old_binary(self):
        old = self.old_binary()
        self.bash(
            self.mock_installer() + "handler_install latest y",
            success=False,
            env={"TEST_INSTALL_MODE": "mismatch"},
        )
        self.assertEqual(self.binary.read_bytes(), old)
        self.assertEqual(self.config.read_bytes(), self.initial_config)

    def test_failed_first_install_removes_partial_binary(self):
        self.bash(
            self.mock_installer() + "handler_install latest y",
            success=False,
            env={"TEST_INSTALL_MODE": "fail"},
        )
        self.assertFalse(self.binary.exists())
        self.assertEqual(self.config.read_bytes(), self.initial_config)

    def test_config_commit_failure_restores_binary(self):
        old = self.old_binary()
        self.bash(
            self.mock_installer()
            + """
mv() {
    if [[ "$*" == *config.json.version.* ]]; then return 1; fi
    command mv "$@"
}
handler_install latest y
""",
            success=False,
        )
        self.assertEqual(self.binary.read_bytes(), old)
        self.assertEqual(self.config.read_bytes(), self.initial_config)

    def test_existing_binary_is_not_reinstalled_without_force(self):
        old = self.old_binary()
        self.bash(
            'ensure_service_users() { touch "${TEST_MARKER}"; return 1; }; '
            'handler_install "" n'
        )
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.binary.read_bytes(), old)
        self.assertEqual(self.config.read_bytes(), self.initial_config)

    def test_proxy_answer_is_committed_only_after_success(self):
        config = json.loads(self.config.read_text())
        config["xray"]["githubProxy"] = ""
        self.config.write_text(json.dumps(config))
        before = self.config.read_bytes()
        body = self.mock_installer() + "handler_install latest y"
        self.bash(body, stdin="y\n", success=False, env={"TEST_INSTALL_MODE": "fail"})
        self.assertEqual(self.config.read_bytes(), before)
        self.bash(body, stdin="y\n")
        self.assertEqual(json.loads(self.config.read_text())["xray"]["githubProxy"], "y")

    def test_invalid_api_version_never_reaches_installer(self):
        self.bash(
            self.mock_installer()
            + "curl() { printf '%s\\n' '[{\"tag_name\":\"--bad-version\"}]'; }; "
            + "handler_install latest y",
            success=False,
        )
        self.assertFalse(self.binary.exists())
        self.assertEqual(self.config.read_bytes(), self.initial_config)

    def test_pinned_installer_checksum_and_direct_download(self):
        result = self.bash(
            'curl() { printf "%s\\n" "$*" >"${TEST_WORK}/url"; cat "${TEST_UPSTREAM}"; }; '
            'fetch_xray_install_script n'
        )
        self.assertEqual(result.stdout, UPSTREAM.read_text())
        url = (self.work / "url").read_text()
        self.assertIn("raw.githubusercontent.com/XTLS/Xray-install/e42df6a", url)
        self.assertNotIn("/main/", url)

    def test_proxy_content_is_checked_before_rewriting_urls(self):
        result = self.bash(
            'curl() { printf "%s\\n" "$*" >"${TEST_WORK}/url"; cat "${TEST_UPSTREAM}"; }; '
            'fetch_xray_install_script y'
        )
        self.assertIn("https://gh-proxy.com/https://github.com", result.stdout)
        self.assertIn("https://gh-proxy.com/https://raw.githubusercontent.com", (self.work / "url").read_text())

    def test_modified_or_failed_installer_download_is_rejected(self):
        for status in [0, 18, 22]:
            with self.subTest(status=status):
                self.bash(
                    "ensure_service_users() { return 0; }; "
                    "curl() { printf '#!/bin/bash\\ntouch \"${TEST_MARKER}\"\\n'; "
                    f"return {status}; }}; handler_install v26.9.13 y y",
                    success=False,
                )
                self.assertFalse(self.marker.exists())
                self.assertEqual(self.config.read_bytes(), self.initial_config)

    def test_user_and_group_failures_are_not_ignored(self):
        for failing in ["groupadd", "useradd", "usermod"]:
            with self.subTest(command=failing):
                body = """
getent() { return 1; }
id() { return 1; }
groupadd() { return 0; }
useradd() { return 0; }
usermod() { return 0; }
"""
                self.bash(body + f"{failing}() {{ return 42; }}; ensure_service_users", success=False)

    def test_runtime_secrets_are_not_world_readable(self):
        for existing in [False, True]:
            with self.subTest(existing=existing):
                if existing:
                    self.runtime.write_text("{}")
                    self.runtime.chmod(0o644)
                self.bash(
                    'id() { return 1; }; cmd_exists() { return 1; }; '
                    'write_xray_runtime_config \'{"privateKey":"secret"}\''
                )
                self.assertEqual(stat.S_IMODE(self.runtime.stat().st_mode), 0o600)

    def test_combined_config_commit_restricts_runtime_permissions(self):
        self.runtime.write_text("{}")
        self.runtime.chmod(0o644)
        self.bash(
            'id() { return 1; }; cmd_exists() { return 1; }; '
            'commit_xray_and_script_config \'{"password":"secret"}\' "$SCRIPT_CONFIG"'
        )
        self.assertEqual(stat.S_IMODE(self.runtime.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)

    def test_service_config_permission_failure_preserves_original(self):
        self.runtime.write_text('{"old":true}\n')
        before = self.runtime.read_bytes()
        self.bash(
            'id() { return 0; }; chown() { return 1; }; cmd_exists() { return 1; }; '
            'write_xray_runtime_config \'{"password":"secret"}\'',
            success=False,
        )
        self.assertEqual(self.runtime.read_bytes(), before)

    def test_nginx_commands_preserve_spaces_and_shell_metacharacters(self):
        body = definitions("service/nginx.sh", "_error_detect") + """
t() { printf '%s' 'Executing ${cmd}'; }
print_info() { :; }
print_error() { exit 1; }
payload='file name; touch should-not-exist $(touch also-not-created)'
_error_detect printf '%s' "$payload" >"${TEST_WORK}/arguments"
[[ $(cat "${TEST_WORK}/arguments") == "$payload" ]]
"""
        self.bash(body, handler=False)
        self.assertFalse((ROOT / "should-not-exist").exists())
        self.assertFalse((ROOT / "also-not-created").exists())

    def test_nginx_command_failure_is_reported(self):
        self.bash(
            definitions("service/nginx.sh", "_error_detect")
            + "\nt() { :; }; print_info() { :; }; print_error() { exit 1; }; _error_detect false",
            handler=False,
            success=False,
        )

    def test_nginx_compiler_flags_keep_security_protections(self):
        result = self.bash(
            definitions("service/nginx.sh", "gen_cflags")
            + '\ngcc() { return 0; }; gen_cflags; printf "%s\\n" "${cflags[@]}"',
            handler=False,
        )
        flags = result.stdout.splitlines()
        self.assertIn("-fstack-protector-strong", flags)
        self.assertIn("-fstack-clash-protection", flags)
        self.assertIn("-D_FORTIFY_SOURCE=2", flags)
        self.assertFalse(any(flag.startswith("-fno-stack") for flag in flags))

    def test_acme_download_failures_never_execute_partial_response(self):
        body = (
            f"source {shlex.quote(str(ROOT / 'lib/cert.sh'))}\n"
            + """
curl() {
    local dest=''
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -o ]]; then dest=$2; shift; fi
        shift
    done
    printf 'touch "${TEST_MARKER}"\n' >"$dest"
    return 18
}
acme_client_download test@example.com
"""
        )
        self.bash(body, handler=False, success=False, env={"TMPDIR": str(self.work)})
        self.assertFalse(self.marker.exists())
        self.assertFalse(list(self.work.glob("install-acme.*")))

    def test_acme_success_and_quoted_temp_path_cleanup(self):
        temp_path = self.work / "temp with 'quotes'"
        temp_path.mkdir()
        self.bash(
            f"source {shlex.quote(str(ROOT / 'lib/cert.sh'))}\n"
            + """
curl() {
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -o ]]; then
            printf 'printf "%%s" "$1" >"${TEST_MARKER}"\n' >"$2"
            return 0
        fi
        shift
    done
    return 1
}
acme_client_download 'test+tag@example.com'
""",
            handler=False,
            env={"TMPDIR": str(temp_path)},
        )
        self.assertEqual(self.marker.read_text(), "email=test+tag@example.com")
        self.assertFalse(list(temp_path.iterdir()))

    def test_complete_tarball_followed_by_download_error_is_not_extracted(self):
        payload = self.work / "payload"
        payload.write_text("should not be extracted")
        archive = self.work / "source.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(payload, arcname="owner-project/payload")
        self.env["TEST_ARCHIVE"] = str(archive)
        self.bash(
            f"source {shlex.quote(str(ROOT / 'install.sh'))}\n"
            + """
curl() {
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -o ]]; then cp "$TEST_ARCHIVE" "$2"; return 18; fi
        shift
    done
    return 1
}
download_github_files "${TEST_WORK}/target" https://example.invalid/archive
""",
            handler=False,
            success=False,
            env={"TMPDIR": str(self.work)},
        )
        self.assertFalse((self.work / "target/payload").exists())
        self.assertFalse(list(self.work.glob("xray-script.*.tar.gz")))

    def test_fixture_hash_matches_pinned_dependency(self):
        checksum = hashlib.sha256(UPSTREAM.read_bytes()).hexdigest()
        self.assertIn(f"XRAY_INSTALL_SHA256='{checksum}'", (ROOT / "core/handler.sh").read_text())

    def test_mkcp_share_seed_supports_current_and_legacy_formats(self):
        streams = [
            {"finalmask": {"udp": [{"type": "mkcp-legacy", "settings": {"value": "test-seed"}}]}},
            {"finalmask": {"udp": [{"type": "mkcp-aes128gcm", "settings": {"password": "test-seed"}}]}},
            {"kcpSettings": {"seed": "test-seed"}},
        ]
        for stream in streams:
            with self.subTest(stream=stream):
                stream["network"] = "kcp"
                self.runtime.write_text(json.dumps({"inbounds": [{}, {
                    "port": 443, "protocol": "vless", "settings": {}, "streamSettings": stream,
                }]}))
                result = self.bash(
                    f"source {shlex.quote(str(ROOT / 'core/share.sh'))}\n"
                    + """
SCRIPT_CONFIG="$(cat "${SCRIPT_CONFIG_PATH}")"
XRAY_CONFIG="$(cat "${XRAY_CONFIG_PATH}")"
get_common_config 1 203.0.113.1
printf '%s' "${CLIENT_CONFIG[seed]}"
""",
                    handler=False,
                )
                self.assertEqual(result.stdout, "test-seed")

    def test_mkcp_config_writes_seed_for_single_and_multi_nodes(self):
        for tag in ["mKCP", "multi"]:
            with self.subTest(tag=tag):
                config = json.loads(self.initial_config)
                config["xray"].update(tag=tag, port=14443, uuid="6b042abc-822d-487a-9887-c6b55c6b506d", kcp="new-seed")
                if tag == "multi":
                    config["xray"]["nodes"] = [{
                        "tag": "mKCP", "port": 14443,
                        "uuid": config["xray"]["uuid"], "kcp": "new-seed",
                    }]
                self.config.write_text(json.dumps(config))
                self.bash("""
id() { return 1; }
cmd_exists() { return 1; }
firewall_owned_open() { return 0; }
handler_lan_open_firewall() { return 0; }
handler_xray_config 1
""")
                generated = json.loads(self.runtime.read_text())
                mask = generated["inbounds"][1]["streamSettings"]["finalmask"]["udp"][0]
                self.assertEqual(mask, {"type": "mkcp-legacy", "settings": {"value": "new-seed"}})

    def test_docker_installer_cleanup_handles_quoted_paths(self):
        temp_path = self.work / "docker temp with 'quotes'"
        temp_path.mkdir()
        self.bash(
            definitions("service/docker.sh", "install_docker") + """
t() { :; }
print_info() { :; }
print_error() { exit 1; }
_os() { printf debian; }
cmd_exists() { return 0; }
wget() {
    printf 'printf "%%s\\n" "${1:-install}" >>"${TEST_MARKER}"\n' >"$2"
}
install_docker
""",
            handler=False,
            env={"TMPDIR": str(temp_path)},
        )
        self.assertEqual(self.marker.read_text().splitlines(), ["--dry-run", "install"])
        self.assertFalse(list(temp_path.iterdir()))

    def test_docker_download_error_cleans_up_without_execution(self):
        self.bash(
            definitions("service/docker.sh", "install_docker") + """
t() { :; }
print_info() { :; }
print_error() { exit 1; }
wget() { printf 'touch "${TEST_MARKER}"\n' >"$2"; return 18; }
install_docker
""",
            handler=False,
            success=False,
            env={"TMPDIR": str(self.work)},
        )
        self.assertFalse(self.marker.exists())
        self.assertFalse(list(self.work.glob("install-docker.*")))

    def test_all_shell_and_json_files_parse(self):
        for path in sorted(ROOT.rglob("*.sh")):
            if ".git" in path.parts:
                continue
            with self.subTest(path=str(path.relative_to(ROOT))):
                result = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
        for path in sorted(ROOT.rglob("*.json")):
            if ".git" not in path.parts:
                with self.subTest(path=str(path.relative_to(ROOT))):
                    json.loads(path.read_text())

    def test_release_versions_are_consistent(self):
        config = json.loads((ROOT / "config.json").read_text())
        self.assertIn(f'SCRIPT_VERSION="{config["version"]}"', (ROOT / "install.sh").read_text())


if __name__ == "__main__":
    unittest.main()
