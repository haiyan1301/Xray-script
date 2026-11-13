"""Offline ACME lifecycle regression tests using real certificate validation."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def definitions(path, *names):
    source = (ROOT / path).read_text(encoding="utf-8")
    result = []
    for name in names:
        match = re.search(rf"^function {re.escape(name)}\(\) [{{(]\n.*?^[}})]$",
                          source, re.MULTILINE | re.DOTALL)
        if not match:
            raise AssertionError(f"Missing function {path}:{name}")
        result.append(match.group())
    return "\n".join(result) + "\n"


class CertificateRenewalFixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-renewal-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.acme = self.work / ".acme.sh"
        self.acme.mkdir()
        self.record = self.acme / "cert.example.com_ecc"
        self.record.mkdir()
        self.conf = self.record / "cert.example.com.conf"
        self.target = self.work / "deployed"
        self.target.mkdir()
        self.log = self.work / "calls.jsonl"
        self.executable = self.acme / "acme.sh"
        self.executable.write_text(r'''#!/usr/bin/python3
import json, os, pathlib, shutil, sys
w = pathlib.Path(os.environ['TEST_WORK'])
args = sys.argv[1:]
with open(w / 'calls.jsonl', 'a') as log:
    log.write(json.dumps(args) + '\n')
record = w / '.acme.sh/cert.example.com_ecc'
if '--renew' in args or '--cron' in args:
    if os.environ.get('FAIL_RENEW'):
        sys.exit(42)
    shutil.copyfile(w / 'valid.pem', record / 'fullchain.cer')
    shutil.copyfile(w / 'key.pem', record / 'cert.example.com.key')
elif '--install-cert' in args:
    # Model acme.sh saving destinations before it installs the pair.
    conf = record / 'cert.example.com.conf'
    conf.write_text(conf.read_text() + "Le_RealFullChainPath='changed-by-install'\n")
    shutil.copyfile(record / 'fullchain.cer', args[args.index('--fullchain-file') + 1])
    shutil.copyfile(record / 'cert.example.com.key', args[args.index('--key-file') + 1])
    if os.environ.get('FAIL_INSTALL'):
        sys.exit(43)
''')
        self.executable.chmod(0o755)
        self.env = os.environ | {"HOME": str(self.work), "TEST_WORK": str(self.work)}
        common = (ROOT / "lib/common.sh").read_text(encoding="utf-8")
        self.body = "\n".join(line for line in common.splitlines() if line.startswith(
            ("readonly DOMAIN_REGEX=", "readonly DOMAIN_MAX_LENGTH="))) + "\n"
        self.body += definitions("lib/common.sh", "valid_ipv4_literal", "valid_ipv6_literal",
                                 "valid_ip_literal", "valid_domain")
        self.body += definitions("lib/cert.sh", "cert_validate_pair", "cert_backup_pair", "cert_restore_pair")
        self.body += definitions("core/handler.sh", "validate_tls_certificate_pair",
                                 "certificate_matches_server_name", "validate_cdn_direct_certificate",
                                 "acme_certificate_config_path", "read_acme_certificate_webroot",
                                 "configure_acme_certificate_challenge", "renew_acme_certificate",
                                 "install_acme_managed_certificate", "install_acme_xray_certificate",
                                 "install_acme_nginx_certificate", "handler_restore_certificate_renewal_hooks",
                                 "run_with_nginx_temporarily_stopped", "handler_renew_ssl",
                                 "handler_cdn_direct_cert_role")
        self.body += r'''
ACME_PATH="${HOME}/.acme.sh/acme.sh"
CUR_FILE=handler
build_certificate_reload_command() { printf 'true'; }
cert_set_permissions() { :; }
reload_certificate_consumer() { :; }
log_error() { printf '%s\n' "$*" >&2; }
t() { printf '%s' "$1"; }
systemctl() {
    printf '%s\n' "$*" >>"${TEST_WORK}/systemctl.log"
    case "$*" in
        '-q is-active nginx') [[ -e "${TEST_WORK}/nginx-active" ]] ;;
        '-q stop nginx') rm -f "${TEST_WORK}/nginx-active" ;;
        '-q start nginx') touch "${TEST_WORK}/nginx-active" ;;
        *) return 99 ;;
    esac
}
'''

    def bash(self, code, env=None):
        return subprocess.run(["bash", "-c", self.body + code], cwd=ROOT,
                              env=self.env | (env or {}), capture_output=True, text=True, timeout=20)

    def write_record(self, webroot):
        metadata = (
            "Le_Domain='cert.example.com'\n"
            "Le_Alt='san.example.com,192.0.2.11'\n"
            "Le_API='https://acme-v02.api.letsencrypt.org/directory'\n"
            "Le_Keylength='ec-256'\nLe_Certificate_Profile='shortlived'\n"
            "Le_RenewalDays='3'\nLe_PreHook='__ACME_BASE64__START_dHJ1ZQ==__ACME_BASE64__END_'\n"
        )
        self.conf.write_text(f"Le_Webroot='{webroot}'\n" + metadata)
        self.conf.chmod(0o600)
        return metadata

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def certificates(self):
        (self.work / "index.txt").touch()
        (self.work / "serial").write_text("01\n")
        (self.work / "ca.cnf").write_text(
            "[ca]\ndefault_ca=local\n[local]\n"
            f"database={self.work}/index.txt\nserial={self.work}/serial\nnew_certs_dir={self.work}\n"
            "default_md=sha256\npolicy=names\n[names]\ncommonName=supplied\n"
        )
        for args in [
            ["req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
             "-nodes", "-subj", "/CN=cert.example.com", "-keyout", str(self.work / "key.pem"),
             "-out", str(self.work / "cert.csr")],
            ["ca", "-selfsign", "-batch", "-notext", "-config", str(self.work / "ca.cnf"),
             "-in", str(self.work / "cert.csr"), "-keyfile", str(self.work / "key.pem"),
             "-startdate", "20200101000000Z", "-enddate", "20200102000000Z",
             "-out", str(self.work / "expired.pem")],
            ["x509", "-req", "-in", str(self.work / "cert.csr"), "-signkey", str(self.work / "key.pem"),
             "-days", "1", "-out", str(self.work / "valid.pem")],
        ]:
            result = subprocess.run(["openssl", *args], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
        shutil.copyfile(self.work / "expired.pem", self.record / "fullchain.cer")
        shutil.copyfile(self.work / "key.pem", self.record / "cert.example.com.key")
        shutil.copyfile(self.work / "expired.pem", self.target / "fullchain.pem")
        shutil.copyfile(self.work / "key.pem", self.target / "privkey.pem")

    def test_http_migration_both_directions_preserves_sans_profile_ca_and_hooks(self):
        for before, consumer, after in [
            ("/var/www/_zerossl", "xray", "no"),
            ("no", "nginx", "/var/www/_zerossl"),
            ("/external/http-root,no", "nginx", "/var/www/_zerossl,/var/www/_zerossl"),
            ("dns_cf,no", "nginx", "dns_cf,/var/www/_zerossl"),
        ]:
            with self.subTest(before=before, consumer=consumer):
                metadata = self.write_record(before)
                result = self.bash('configure_acme_certificate_challenge cert.example.com "$CONSUMER"',
                                   {"CONSUMER": consumer})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.conf.read_text(), f"Le_Webroot='{after}'\n" + metadata)
                self.assertEqual(self.conf.stat().st_mode & 0o777, 0o600)
                self.assertFalse(self.calls())

    def test_dns_challenge_is_not_converted_or_executed(self):
        for challenge in ["dns_cf", "dns_aws,dns_cf", "dns"]:
            with self.subTest(challenge=challenge):
                self.write_record(challenge)
                with self.conf.open("a") as file:
                    file.write(f"Unrelated=$(touch {self.work}/executed)\n")
                original = self.conf.read_bytes()
                result = self.bash('configure_acme_certificate_challenge cert.example.com xray')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.conf.read_bytes(), original)
                self.assertFalse((self.work / "executed").exists())

    def test_invalid_or_unsupported_challenge_does_not_change_record(self):
        for contents in ["Le_Webroot='nginx'\n", "Le_Webroot='tls'\n", "Le_Webroot=\"no\"\n",
                         "Le_Webroot='no'\nLe_Webroot='dns_cf'\n", "Le_Webroot='no,,dns_cf'\n",
                         "Le_Webroot='no'; touch unwanted\n", "Le_Alt='no'\n"]:
            with self.subTest(contents=contents):
                self.conf.write_text(contents)
                result = self.bash('configure_acme_certificate_challenge cert.example.com xray')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.conf.read_text(), contents)
                self.assertFalse(self.calls())

    def test_record_paths_reject_traversal_and_symlinks(self):
        self.write_record("no")
        for name in ["../escape", "-x", "a/b.example.com", "$(id)", ""]:
            with self.subTest(name=name):
                result = self.bash('acme_certificate_config_path "$IDENTIFIER"', {"IDENTIFIER": name})
                self.assertNotEqual(result.returncode, 0)
        original = self.conf.read_text()
        self.conf.unlink()
        other = self.work / "other.conf"
        other.write_text(original)
        self.conf.symlink_to(other)
        result = self.bash('configure_acme_certificate_challenge cert.example.com nginx')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(other.read_text(), original)

    def test_standalone_renewal_restores_nginx_on_success_and_failure(self):
        self.certificates()
        for fail in [False, True]:
            with self.subTest(fail=fail):
                self.write_record("/var/www/_zerossl")
                (self.work / "nginx-active").touch()
                result = self.bash('renew_acme_certificate cert.example.com xray',
                                   {"FAIL_RENEW": "1" if fail else ""})
                self.assertEqual(result.returncode == 0, not fail, result.stderr)
                self.assertTrue((self.work / "nginx-active").exists())
                commands = (self.work / "systemctl.log").read_text()
                self.assertIn("-q stop nginx", commands)
                self.assertIn("-q start nginx", commands)
                self.assertIn("Le_Webroot='no'", self.conf.read_text())

    def test_webroot_and_dns_renewal_keep_nginx_serving(self):
        self.certificates()
        for challenge, consumer in [("no", "nginx"), ("dns_cf", "xray")]:
            with self.subTest(challenge=challenge):
                self.write_record(challenge)
                (self.work / "nginx-active").touch()
                result = self.bash('renew_acme_certificate cert.example.com "$CONSUMER"',
                                   {"CONSUMER": consumer})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((self.work / "systemctl.log").exists())

    def renew_entry(self):
        return r'''
SCRIPT_CONFIG='{"xray":{"tag":"hy2"}}'
list_active_acme_certificate_consumers() {
    printf 'cert.example.com\t%s\tcert.example.com\t%s/deployed\n' "${CONSUMER}" "${TEST_WORK}"
}
exec_ssl() { "${ACME_PATH}" --cron --force; }
current_protocol_uses_nginx() { [[ "${CONSUMER}" == nginx ]]; }
handler_nginx_restart() { touch "${TEST_WORK}/nginx-restarted"; }
handler_restart() { touch "${TEST_WORK}/restarted"; }
handler_renew_ssl
'''

    def test_expired_certificate_reaches_renewal_before_install_and_validates_new_pair(self):
        self.certificates()
        for consumer in ["nginx", "xray"]:
            with self.subTest(consumer=consumer):
                self.write_record("no" if consumer == "nginx" else "/var/www/_zerossl")
                shutil.copyfile(self.work / "expired.pem", self.record / "fullchain.cer")
                shutil.copyfile(self.work / "expired.pem", self.target / "fullchain.pem")
                self.log.write_text("")
                result = self.bash(self.renew_entry(), {"CONSUMER": consumer})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([call[0] for call in self.calls()], ["--cron", "--install-cert"])
                self.assertEqual((self.target / "fullchain.pem").read_bytes(), (self.work / "valid.pem").read_bytes())
                self.assertTrue((self.work / "restarted").exists())

    def test_cdn_manual_renewal_does_not_preinstall_expired_certificate(self):
        result = self.bash(r'''
SCRIPT_CONFIG='{"xray":{"tag":"cdn"}}'
get_cdn_backend() { echo xray; }
handler_restore_certificate_renewal_hooks() { return 81; }
handler_cdn_direct_cert() { [[ "$1" == renew ]] && touch "${TEST_WORK}/renewed"; }
handler_restart() { :; }
handler_renew_ssl
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.work / "renewed").exists())

    def test_direct_cdn_role_renews_expired_certificate_and_rebinds_deployment(self):
        self.certificates()
        self.write_record("/var/www/_zerossl")
        result = self.bash(r'''
SCRIPT_CONFIG='{"xray":{"cdnCertSource":"1","cdnCertHostname":"cert.example.com"},"nginx":{"cdn":"cert.example.com"}}'
SCRIPT_CONFIG_PATH="${TEST_WORK}/saved.json"
exec_check() { :; }
get_cdn_direct_cert_dir() { printf '%s/deployed' "${TEST_WORK}"; }
acme_main_domain_for_name() { printf 'cert.example.com'; }
handler_ssl_install() { :; }
write_config() { printf '%s' "$1" >"$2"; }
log_info() { :; }
handler_cdn_direct_cert_role renew cdn
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in self.calls()], ["--renew", "--install-cert"])
        self.assertEqual((self.target / "fullchain.pem").read_bytes(), (self.work / "valid.pem").read_bytes())
        self.assertIn("Le_Webroot='no'", self.conf.read_text())

    def test_renew_failure_preserves_deployed_pair_and_never_installs_or_restarts(self):
        self.certificates()
        self.write_record("no")
        original = (self.target / "fullchain.pem").read_bytes()
        result = self.bash(self.renew_entry(), {"CONSUMER": "xray", "FAIL_RENEW": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call[0] for call in self.calls()], ["--cron"])
        self.assertEqual((self.target / "fullchain.pem").read_bytes(), original)
        self.assertFalse((self.work / "restarted").exists())

    def test_install_failure_rolls_back_challenge_hooks_and_certificate_pair(self):
        self.certificates()
        self.write_record("/var/www/_zerossl")
        original = self.conf.read_bytes()
        old_pair = (self.target / "fullchain.pem").read_bytes()
        shutil.copyfile(self.work / "valid.pem", self.record / "fullchain.cer")
        result = self.bash('install_acme_managed_certificate cert.example.com cert.example.com '
                           '"${TEST_WORK}/deployed" xray', {"FAIL_INSTALL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.conf.read_bytes(), original)
        self.assertEqual((self.target / "fullchain.pem").read_bytes(), old_pair)
        self.assertFalse(list(self.work.glob(".xray-cert-backup.*")))

    def test_failed_config_rollback_keeps_recovery_backup(self):
        self.certificates()
        self.write_record("/var/www/_zerossl")
        original = self.conf.read_bytes()
        result = self.bash(r'''
cp() {
    if [[ "$*" == *'/acme.conf '* ]]; then return 56; fi
    command cp "$@"
}
install_acme_managed_certificate cert.example.com cert.example.com "${TEST_WORK}/deployed" xray
''', {"FAIL_INSTALL": "1"})
        self.assertNotEqual(result.returncode, 0)
        backups = list(self.work.glob(".xray-cert-backup.*/acme.conf"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)
        self.assertIn(str(backups[0].parent), result.stderr)

    def test_renew_all_still_runs_with_no_active_consumers(self):
        self.certificates()
        result = self.bash(r'''
SCRIPT_CONFIG='{"xray":{"tag":"reality"}}'
list_active_acme_certificate_consumers() { :; }
exec_ssl() { "${ACME_PATH}" --cron --force; }
current_protocol_uses_nginx() { return 1; }
handler_restart() { :; }
handler_renew_ssl
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in self.calls()], ["--cron"])


if __name__ == "__main__":
    unittest.main()
