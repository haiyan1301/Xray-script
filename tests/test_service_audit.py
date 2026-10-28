"""Service failure-path checks; all Docker commands are simulated."""

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

    def bash(self, body):
        return subprocess.run(
            ["bash", "-c", body],
            cwd=ROOT,
            env=os.environ | {"TEST_WORK": str(self.work)},
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


if __name__ == "__main__":
    unittest.main()
