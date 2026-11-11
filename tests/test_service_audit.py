"""Service failure-path checks; all Docker commands are simulated."""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def definitions(path, *names):
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


class ServiceAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-service-audit-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def bash(self, body, env=None):
        return subprocess.run(
            ["bash", "-c", body],
            cwd=ROOT,
            env=os.environ | {"TEST_WORK": str(self.work)} | (env or {}),
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_readiness_rejects_running_auxiliary_container(self):
        body = definitions("service/docker.sh", "wait_container_running") + r'''
docker() {
    case "$*" in
        inspect*) return 1 ;;
        'compose ps --all --quiet cloudreve_v4') return 0 ;;
        'compose ps '*) printf '%s\n' redis ;;
        *) return 97 ;;
    esac
}
wait_container_running cloudreve_v4 0 0
'''
        self.assertNotEqual(self.bash(body).returncode, 0)

    def test_readiness_resolves_renamed_main_container_only(self):
        for status in ["running", "exited", "restarting"]:
            with self.subTest(status=status):
                body = definitions("service/docker.sh", "wait_container_running") + r'''
docker() {
    case "$*" in
        'inspect --format={{.State.Status}} cloudreve_v4') return 1 ;;
        'compose ps --all --quiet cloudreve_v4') printf '%s\n' main-id ;;
        'inspect --format={{.State.Status}} main-id') printf '%s\n' "''' + status + r'''" ;;
        'compose ps '*) printf '%s\n' redis ;;
        *) return 97 ;;
    esac
}
wait_container_running cloudreve_v4 0 0
'''
                result = self.bash(body)
                self.assertEqual(result.returncode == 0, status == "running", result.stderr)

    def test_failed_purge_preserves_project_configuration_and_data(self):
        for version in [3, 4]:
            with self.subTest(version=version):
                project = self.work / f"v{version}"
                project.mkdir()
                (project / "docker-compose.yaml").write_text("services: {}\n")
                data = project / "data"
                data.write_text("existing data")
                body = definitions("service/docker.sh", f"purge_cloudreve_v{version}")
                body += f"\nCLOUDREVE_V{version}_DIR={shlex.quote(str(project))}\n"
                body += r'''
cloudreve_project_present() { return 0; }
t() { printf '%s\n' "$1"; }
print_warn() { :; }
print_error() { printf '%s\n' "$*" >&2; exit 1; }
docker() {
    printf '%s\n' "$*" >>"${TEST_WORK}/commands"
    return 42
}
'''
                body += f"purge_cloudreve_v{version}\n"
                result = self.bash(body)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((project / "docker-compose.yaml").is_file())
                self.assertEqual(data.read_text(), "existing data")

    def update_body(self, pull_status=0):
        project = self.work / "v4"
        project.mkdir(exist_ok=True)
        body = definitions("service/docker.sh", "update_cloudreve_v4")
        body += f"\nCLOUDREVE_V4_DIR={shlex.quote(str(project))}\n"
        body += r'''
cloudreve_project_present() { return 0; }
t() { printf '%s\n' "$1"; }
print_info() { :; }
print_error() { printf '%s\n' "$*" >&2; exit 1; }
wait_container_running() { return 0; }
docker() {
    printf '%s\n' "$*" >>"${TEST_WORK}/commands"
    if [[ "$*" == 'compose pull' ]]; then
        return ''' + str(pull_status) + r'''
    fi
    return 0
}
update_cloudreve_v4
'''
        return body

    def test_failed_image_pull_never_stops_or_recreates_service(self):
        result = self.bash(self.update_body(pull_status=42))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.work / "commands").read_text().splitlines(), ["compose pull"])

    def test_successful_update_pulls_before_recreating_service(self):
        result = self.bash(self.update_body())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.work / "commands").read_text().splitlines(),
            ["compose pull", "compose up -d"],
        )

    def test_certificate_backup_rejects_dangling_links_in_either_file(self):
        for name in ["fullchain.pem", "privkey.pem"]:
            with self.subTest(name=name):
                cert = self.work / name
                cert.mkdir()
                (cert / name).symlink_to(self.work / "missing-target")
                backup = self.work / (name + "-backup")
                backup.mkdir()
                body = f"source {shlex.quote(str(ROOT / 'lib/cert.sh'))}\n"
                body += f"cert_backup_pair {shlex.quote(str(cert))} {shlex.quote(str(backup))}\n"
                result = self.bash(body)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(list(backup.iterdir()), [])

    def test_certificate_backup_and_restore_preserves_regular_pair(self):
        cert = self.work / "cert"
        backup = self.work / "backup"
        cert.mkdir()
        backup.mkdir()
        (cert / "fullchain.pem").write_text("certificate")
        (cert / "privkey.pem").write_text("private key")
        body = f"source {shlex.quote(str(ROOT / 'lib/cert.sh'))}\n"
        body += f"cert_dir={shlex.quote(str(cert))}\nbackup_dir={shlex.quote(str(backup))}\n"
        body += r'''
flags=$(cert_backup_pair "$cert_dir" "$backup_dir") || exit 1
[[ "$flags" == '1 1' ]] || exit 2
printf invalid >"$cert_dir/fullchain.pem"
rm "$cert_dir/privkey.pem"
cert_restore_pair "$cert_dir" "$backup_dir" 1 1
'''
        result = self.bash(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((cert / "fullchain.pem").read_text(), "certificate")
        self.assertEqual((cert / "privkey.pem").read_text(), "private key")

    def test_failed_nginx_make_install_stops_before_service_preparation(self):
        body = definitions("service/nginx.sh", "_error_detect", "source_install") + r'''
NGINX_PATH="${TEST_WORK}/nginx"
source_compile() { return 0; }
t() { printf '%s\n' "$1"; }
print_info() { :; }
print_error() { printf '%s\n' "$*" >&2; exit 1; }
id() { return 0; }
make() { printf 'make %s\n' "$*" >>"${TEST_WORK}/commands"; return 42; }
mkdir() { printf 'mkdir %s\n' "$*" >>"${TEST_WORK}/commands"; }
chown() { printf 'chown %s\n' "$*" >>"${TEST_WORK}/commands"; }
ln() { printf 'ln %s\n' "$*" >>"${TEST_WORK}/commands"; }
source_install
'''
        result = self.bash(body)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.work / "commands").read_text().splitlines(), ["make install"])


    def test_warp_build_skips_when_assets_fingerprint_matches(self):
        body = definitions("service/docker.sh", "build_warp") + r'''
WARP_IMAGE='xray-script-warp:latest'
WARP_ASSETS_LABEL='xray-script-warp.assets'
WARP_BUILD_CONTEXT='/unused'
t() { printf '%s\n' "$1"; }
log_info() { :; }
log_error() { printf '%s\n' "$*" >&2; }
print_info() { :; }
warp_assets_hash() { printf 'asset-hash\n'; }
_warp_image_assets_label() { printf 'asset-hash\n'; }
docker() { printf '%s\n' "$*" >>"${TEST_WORK}/commands"; return 0; }
build_warp
'''
        result = self.bash(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = (self.work / "commands").read_text().splitlines()
        self.assertIn("info", commands)
        self.assertIn("image inspect xray-script-warp:latest", commands)
        self.assertFalse([line for line in commands if line.startswith("build ")], commands)

    def test_warp_build_rebuilds_with_fingerprint_label_on_mismatch(self):
        body = definitions("service/docker.sh", "build_warp") + r'''
WARP_IMAGE='xray-script-warp:latest'
WARP_ASSETS_LABEL='xray-script-warp.assets'
WARP_BUILD_CONTEXT='/unused'
t() { printf '%s\n' "$1"; }
log_info() { :; }
log_error() { printf '%s\n' "$*" >&2; }
print_info() { :; }
warp_assets_hash() { printf 'asset-hash\n'; }
_warp_image_assets_label() { return 1; }
docker() {
    printf '%s\n' "$*" >>"${TEST_WORK}/commands"
    case "$*" in
        info) return 0 ;;
        'image inspect xray-script-warp:latest') return 0 ;;
        build*) return 0 ;;
        *) return 97 ;;
    esac
}
build_warp
'''
        result = self.bash(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = (self.work / "commands").read_text().splitlines()
        self.assertIn(
            "build -t xray-script-warp:latest --label xray-script-warp.assets=asset-hash /unused",
            commands,
        )

    def test_warp_disable_persists_restart_policy_before_stop(self):
        body = definitions("service/docker.sh", "disable_warp") + r'''
WARP_NAME='xray-script-warp'
t() { printf '%s\n' "$1"; }
print_warn() { :; }
print_info() { :; }
log_warn() { printf '%s\n' "$*" >&2; }
_warp_container_state() { printf 'running\n'; }
docker() {
    printf '%s\n' "$*" >>"${TEST_WORK}/commands"
    return 0
}
disable_warp
'''
        result = self.bash(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = (self.work / "commands").read_text().splitlines()
        self.assertEqual(
            commands,
            [
                "info",
                "update --restart=no xray-script-warp",
                "stop xray-script-warp",
            ],
        )

    def test_warp_status_tokens_cover_all_states(self):
        cases = [
            ("docker_unavailable", 1, "", 0),
            ("missing", 0, "missing", 0),
            ("stopped", 0, "stopped", 0),
            ("enabled", 0, "running", 0),
            ("unhealthy", 0, "running", 1),
        ]
        body = definitions("service/docker.sh", "_warp_status") + r'''
WARP_NAME='xray-script-warp'
docker() { [[ "${TEST_DOCKER_INFO_OK}" == 1 ]]; }
_warp_container_state() { printf '%s\n' "${TEST_WARP_STATE}"; }
_warp_container_connected() { [[ "${TEST_WARP_CONNECTED}" == 0 ]]; }
_warp_status
'''
        for token, info_failed, state, connected_rc in cases:
            with self.subTest(token=token):
                result = self.bash(
                    body,
                    env={
                        "TEST_DOCKER_INFO_OK": "0" if info_failed else "1",
                        "TEST_WARP_STATE": state,
                        "TEST_WARP_CONNECTED": str(connected_rc),
                    },
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), token)

    def test_warp_commit_accepts_created_marker_without_swapped(self):
        transaction = self.work / "tx"
        transaction.mkdir()
        (transaction / "created").write_text("")
        body = definitions("service/docker.sh", "commit_warp_reset") + f'''
WARP_TRANSACTION_DIR={shlex.quote(str(transaction))}
WARP_NAME='xray-script-warp'
WARP_RESET_IMAGE='xray-script-warp:reset-new'
WARP_IMAGE='xray-script-warp:latest'
t() {{ printf '%s\n' "$1"; }}
log_warn() {{ printf '%s\n' "$*" >&2; }}
_warp_container_state() {{ printf 'running\n'; }}
wait_for_warp() {{ return 0; }}
_warp_finish_transaction_cleanup() {{ :; }}
docker() {{
    printf '%s\n' "$*" >>"${{TEST_WORK}}/commands"
    return 0
}}
commit_warp_reset
'''
        result = self.bash(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((transaction / "committed").is_file())
        self.assertIn(
            "tag xray-script-warp:reset-new xray-script-warp:latest",
            (self.work / "commands").read_text().splitlines(),
        )

    def test_warp_commit_rejects_prepare_without_created_or_swapped_marker(self):
        transaction = self.work / "tx-empty"
        transaction.mkdir()
        body = definitions("service/docker.sh", "commit_warp_reset") + f'''
WARP_TRANSACTION_DIR={shlex.quote(str(transaction))}
WARP_NAME='xray-script-warp'
WARP_RESET_IMAGE='xray-script-warp:reset-new'
WARP_IMAGE='xray-script-warp:latest'
t() {{ printf '%s\n' "$1"; }}
log_warn() {{ :; }}
docker() {{ return 0; }}
commit_warp_reset
'''
        result = self.bash(body)
        self.assertNotEqual(result.returncode, 0)


    def test_warp_user_route_rules_drop_switch_managed_default_rules(self):
        body = definitions("core/handler.sh", "user_route_rules") + r'''
printf '%s' '[
  {"ruleTag":"block-ip","ip":["1.1.1.1"],"outboundTag":"block"},
  {"ruleTag":"warp-ip","ip":["1.0.0.0/8"],"outboundTag":"warp"},
  {"ruleTag":"bt","protocol":["bittorrent"],"outboundTag":"block"},
  {"ruleTag":"cn-ip","ip":["geoip:cn"],"outboundTag":"block"},
  {"ruleTag":"ad-domain","domain":["geosite:category-ads-all"],"outboundTag":"block"},
  {"ruleTag":"api","inboundTag":["api"],"outboundTag":"api"}
]' | user_route_rules
'''
        result = self.bash(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        tags = [rule["ruleTag"] for rule in json.loads(result.stdout)]
        self.assertEqual(tags, ["block-ip", "warp-ip"])

    def test_warp_health_requires_expected_container_runtime(self):
        body = definitions("service/docker.sh", "warp_health") + r'''
WARP_NAME='xray-script-warp'
_warp_status() { printf 'enabled\n'; }
_warp_container_has_expected_runtime() { return "${TEST_RUNTIME_OK}"; }
warp_health
'''
        self.assertEqual(self.bash(body, env={"TEST_RUNTIME_OK": "0"}).returncode, 0)
        self.assertNotEqual(self.bash(body, env={"TEST_RUNTIME_OK": "1"}).returncode, 0)

    def test_warp_obtain_ip_rejects_legacy_container_without_loopback_port(self):
        body = definitions("service/docker.sh", "obtain_container_ip") + r'''
WARP_NAME='xray-script-warp'
WARP_HOST='127.0.0.1'
docker() { printf 'running\n'; }
sleep() { SECONDS=$((SECONDS + 11)); }   # 跳过 10s 等待窗口，快速命中超时
_warp_container_connected() { return 0; }
_warp_container_has_expected_runtime() { return 1; }
obtain_container_ip
'''
        result = self.bash(body)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

        body = definitions("service/docker.sh", "obtain_container_ip") + r'''
WARP_NAME='xray-script-warp'
WARP_HOST='127.0.0.1'
docker() { printf 'running\n'; }
_warp_container_connected() { return 0; }
_warp_container_has_expected_runtime() { return 0; }
obtain_container_ip
'''
        result = self.bash(body)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "127.0.0.1")


if __name__ == "__main__":
    unittest.main()
