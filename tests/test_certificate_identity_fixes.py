"""Certificate identity/ACME record regression tests; no network or services."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def definitions(path, *names):
    source = (ROOT / path).read_text(encoding="utf-8")
    result = []
    for name in names:
        match = re.search(
            rf"^function {re.escape(name)}\(\) [{{(]\n.*?^[}})]$",
            source, re.MULTILINE | re.DOTALL,
        )
        if not match:
            raise AssertionError(f"Missing function {path}:{name}")
        result.append(match.group())
    return "\n".join(result) + "\n"


def common_cron_definitions():
    source = (ROOT / "lib/common.sh").read_text(encoding="utf-8")
    constants = "\n".join(
        line for line in source.splitlines()
        if line.startswith(("readonly DOMAIN_REGEX=", "readonly DOMAIN_MAX_LENGTH="))
    )
    return constants + "\n" + definitions(
        "lib/common.sh", "valid_ipv4_literal", "valid_ipv6_literal",
        "valid_ip_literal", "valid_domain", "hy2_ip_cron_identifier",
        "is_managed_hy2_ip_cron_line",
    )


QUIET = """
t() { printf '%s' "$1"; }
log_info() { :; }
log_config() { :; }
log_error() { :; }
"""


class CertificateIdentityFixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-cert-identity-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.env = os.environ | {"TEST_WORK": str(self.work)}

    def bash(self, body, env=None):
        return subprocess.run(
            ["bash", "-c", body], cwd=ROOT, env=self.env | (env or {}),
            capture_output=True, text=True, timeout=20,
        )

    def make_certificate(self):
        result = subprocess.run([
            "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
            "ec_paramgen_curve:P-256", "-nodes", "-subj", "/CN=right.example.com",
            "-addext", "subjectAltName=DNS:right.example.com,DNS:*.example.org,"
            "IP:192.0.2.11,IP:2001:db8::1", "-days", "1", "-keyout",
            str(self.work / "key.pem"), "-out", str(self.work / "cert.pem"),
        ], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def name_check(self, name, *, legacy=False):
        body = definitions("lib/cert.sh", "cert_validate_pair")
        body += definitions(
            "core/handler.sh", "validate_tls_certificate_pair",
            "certificate_matches_server_name", "validate_cdn_direct_certificate",
        )
        if legacy:
            # Real X509 name comparison, with the legacy CLI exit semantics:
            # -checkhost/-checkip mismatches print NOT but exit zero.
            body += r'''
openssl() {
    case "$*" in
        *' -checkhost '*|*' -checkip '*) command openssl "$@"; return 0 ;;
        *) command openssl "$@" ;;
    esac
}
'''
        body += r'''
validate_cdn_direct_certificate "${TEST_WORK}/cert.pem" "${TEST_WORK}/key.pem" "${TEST_NAME}"
'''
        return self.bash(body, {"TEST_NAME": name})

    def test_name_checks_accept_matching_names_on_current_and_legacy_openssl(self):
        self.make_certificate()
        for legacy in [False, True]:
            for name in ["right.example.com", "a.example.org", "192.0.2.11", "2001:db8::1"]:
                with self.subTest(legacy=legacy, name=name):
                    result = self.name_check(name, legacy=legacy)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_name_checks_reject_mismatches_even_when_legacy_cli_exits_zero(self):
        self.make_certificate()
        for legacy in [False, True]:
            for name in ["wrong.example.com", "example.org", "a.b.example.org", "192.0.2.12", "2001:db8::2"]:
                with self.subTest(legacy=legacy, name=name):
                    result = self.name_check(name, legacy=legacy)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_name_checks_require_affirmative_output_and_success(self):
        body = definitions("core/handler.sh", "certificate_matches_server_name")
        body += r'''
openssl() {
    if [[ "$*" == 'x509 -help' ]]; then printf '%s\n' '-checkhost'; return 0; fi
    printf '%s' "${TEST_OUTPUT}"
    return "${TEST_EXIT}"
}
certificate_matches_server_name unused right.example.com
'''
        cases = [
            ("", "0"),
            ("Hostname right.example.com does NOT match certificate", "0"),
            ("Hostname right.example.com does match certificate", "2"),
            ("Hostname right.example.com does match certificate\nextra output", "0"),
        ]
        for output, status in cases:
            with self.subTest(output=output, status=status):
                result = self.bash(body, {"TEST_OUTPUT": output, "TEST_EXIT": status})
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def acme_mock(self):
        path = self.work / "acme.sh"
        path.write_text(
            '#!/usr/bin/env bash\nprintf "%s\\n" "$TEST_ACME_LIST"\n'
            'exit "${TEST_ACME_EXIT:-0}"\n', encoding="utf-8",
        )
        path.chmod(0o700)
        return f'ACME_PATH="{path}"\n'

    def lookup(self, name, rows, status="0"):
        body = definitions("core/handler.sh", "acme_main_domain_for_name")
        body += self.acme_mock()
        body += 'acme_main_domain_for_name "${TEST_NAME}"\n'
        return self.bash(body, {
            "TEST_NAME": name,
            "TEST_ACME_LIST": "Main_Domain KeyLength SAN_Domains\n" + rows,
            "TEST_ACME_EXIT": status,
        })

    def test_acme_record_prefers_exact_primary_over_san_and_wildcard(self):
        rows = "*.example.com ec-256 no\nother.example.net ec-256 api.example.com\nAPI.example.com ec-256 no"
        result = self.lookup("api.EXAMPLE.com", rows)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "API.example.com")

    def test_acme_record_prefers_exact_san_over_wildcard(self):
        rows = "*.example.com ec-256 no\ncert.example.net ec-256 www.example.net,api.example.com"
        result = self.lookup("api.example.com", rows)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "cert.example.net")

    def test_acme_record_supports_wildcard_primary_and_san(self):
        for rows, expected in [
            ('*.example.com "ec-256" no', "*.example.com"),
            ('cert.example.net "ec-256" *.example.com;other.example.net', "cert.example.net"),
        ]:
            with self.subTest(rows=rows):
                result = self.lookup("api.example.com", rows)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_acme_wildcards_do_not_match_apex_deep_hosts_or_ip_addresses(self):
        rows = "*.example.com ec-256 no\n*.0.2.11 ec-256 no\n*.example.net 2048 no"
        for name in ["example.com", "a.b.example.com", "badexample.com", "192.0.2.11", "api.example.net"]:
            with self.subTest(name=name):
                result = self.lookup(name, rows)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_acme_list_failure_cannot_return_a_partially_printed_match(self):
        result = self.lookup("api.example.com", "api.example.com ec-256 no", "42")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_acme_record_rejects_ambiguous_sans_unless_exact_primary_exists(self):
        rows = "first.example.net ec-256 api.example.com\nsecond.example.net ec-256 api.example.com"
        result = self.lookup("api.example.com", rows)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        result = self.lookup("api.example.com", rows + "\napi.example.com ec-256 no")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "api.example.com")

    def test_wildcard_record_keeps_configured_consumer_in_renewal_callback(self):
        body = definitions(
            "core/handler.sh", "acme_main_domain_for_name",
            "emit_active_acme_certificate_consumer", "list_active_acme_certificate_consumers",
        ) + self.acme_mock()
        body += r'''
NGINX_CONFIG_DIR="${TEST_WORK}/nginx"
SCRIPT_CONFIG='{"xray":{"tag":"CDN"},"nginx":{"cdn":"api.example.com","cdnDown":"","certificates":{"cdn":{"source":"1","hostname":"api.example.com"}}}}'
get_cdn_backend() { printf nginx; }
list_active_acme_certificate_consumers '*.example.com'
'''
        result = self.bash(body, {"TEST_ACME_LIST": "Main_Domain KeyLength SAN_Domains\n*.example.com ec-256 no"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"*.example.com\tnginx\tapi.example.com\t{self.work}/nginx/certs/api.example.com")

    def test_cleanup_does_not_stop_wildcard_record_used_by_another_host(self):
        body = definitions(
            "core/handler.sh", "acme_main_domain_for_name",
            "current_config_uses_acme_main_domain", "cleanup_acme_certificate_if_unused",
        ) + self.acme_mock()
        body += r'''
NGINX_CONFIG_DIR="${TEST_WORK}/nginx"
SCRIPT_CONFIG='{"xray":{"tag":"CDN"},"nginx":{"certificates":{"cdn":{"source":"1","hostname":"api.example.com"}}}}'
get_cdn_backend() { printf nginx; }
protocol_tag_uses() { return 1; }
exec_ssl() { printf '%s\n' "$*" >"${TEST_WORK}/ssl-calls"; }
cleanup_acme_certificate_if_unused old.example.com n
'''
        result = self.bash(body, {"TEST_ACME_LIST": "Main_Domain KeyLength SAN_Domains\n*.example.com ec-256 no"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.work / "ssl-calls").exists())

    def test_cleanup_stops_unused_wildcard_by_resolved_primary(self):
        body = definitions(
            "core/handler.sh", "acme_main_domain_for_name",
            "current_config_uses_acme_main_domain", "cleanup_acme_certificate_if_unused",
        ) + self.acme_mock()
        body += r'''
NGINX_CONFIG_DIR="${TEST_WORK}/nginx"
SCRIPT_CONFIG='{"xray":{"tag":"Vision"},"nginx":{}}'
protocol_tag_uses() { return 1; }
exec_ssl() { printf '%s\n' "$@" >"${TEST_WORK}/ssl-calls"; }
cleanup_acme_certificate_if_unused old.example.com n
'''
        result = self.bash(body, {"TEST_ACME_LIST": "Main_Domain KeyLength SAN_Domains\n*.example.com ec-256 no"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / "ssl-calls").read_text().splitlines(), ["--stop-renew", "--domain=*.example.com", "--keep-cert"])

    def cron_body(self):
        body = common_cron_definitions()
        body += definitions("core/handler.sh", "configure_hy2_ip_renewal_cron")
        return body + r'''
read_current_crontab() { cat "${TEST_WORK}/existing.cron"; }
crontab() { cat >"${TEST_WORK}/updated.cron"; }
'''

    def cron_line(self, identifier, *, marker=True):
        home = os.environ["HOME"]
        line = f"17 3 */3 * * {home}/.acme.sh/acme.sh --renew -d {identifier} --ecc --force --home {home}/.acme.sh >/dev/null 2>&1"
        return line + (" # xray-script-hy2-ip-renew" if marker else "")

    def test_cron_replaces_managed_ip_or_dns_record_and_preserves_user_jobs(self):
        user_line = self.cron_line("user.example.com", marker=False)
        ordinary = "0 0 * * * echo leave-this-job-alone"
        original = "\n".join([
            self.cron_line("192.0.2.11", marker=False),
            self.cron_line("old-primary.example.com"), user_line, ordinary,
        ]) + "\n"
        (self.work / "existing.cron").write_text(original)
        result = self.bash(self.cron_body() + "configure_hy2_ip_renewal_cron 2 new-primary.example.com\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / "updated.cron").read_text().splitlines(), [
            user_line, ordinary, self.cron_line("new-primary.example.com"),
        ])

    def test_cron_cleanup_recognizes_marked_dns_primary_records(self):
        user_line = self.cron_line("user.example.com", marker=False)
        (self.work / "existing.cron").write_text(self.cron_line("primary.example.com") + "\n" + user_line + "\n")
        result = self.bash(self.cron_body() + "configure_hy2_ip_renewal_cron cleanup ''\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / "updated.cron").read_text().splitlines(), [user_line])

    def test_cron_rejects_empty_or_unsafe_primary_without_changing_crontab(self):
        for identifier in ["", "x;touch /tmp/unwanted", "$(id)", "-x", "999.999.999.999"]:
            with self.subTest(identifier=identifier):
                result = self.bash(self.cron_body() + 'configure_hy2_ip_renewal_cron 2 "$TEST_PRIMARY"\n', {"TEST_PRIMARY": identifier})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.work / "updated.cron").exists())

    def test_hy2_ip_san_reuse_schedules_resolved_primary_record(self):
        for primary in ["192.0.2.10", "primary.example.com"]:
            with self.subTest(primary=primary):
                (self.work / "existing.cron").write_text("0 0 * * * echo keep\n")
                body = self.cron_body() + definitions("core/handler.sh", "handler_hy2_cert") + QUIET
                body += r'''
SCRIPT_CONFIG='{"xray":{"hy2CertSource":"2","hy2CertDomain":"192.0.2.11"},"nginx":{}}'
SCRIPT_CONFIG_PATH="${TEST_WORK}/saved.json"
exec_check() { :; }
get_hy2_cert_dir() { printf '%s/hy2' "${TEST_WORK}"; }
prompt_cert_reuse() { printf '%s' "${TEST_PRIMARY}"; }
acme_main_domain_for_name() { printf '%s' "${TEST_PRIMARY}"; }
install_acme_xray_certificate() { touch "$3/fullchain.pem" "$3/privkey.pem"; }
validate_cdn_direct_certificate() { :; }
set_xray_certificate_permissions() { :; }
write_config() { printf '%s' "$1" >"$2"; }
handler_hy2_cert
'''
                result = self.bash(body, {"TEST_PRIMARY": primary})
                self.assertEqual(result.returncode, 0, result.stderr)
                config = json.loads((self.work / "saved.json").read_text())
                self.assertEqual(config["xray"]["hy2CertAcmeDomain"], primary)
                lines = (self.work / "updated.cron").read_text().splitlines()
                self.assertEqual(lines, ["0 0 * * * echo keep", self.cron_line(primary)])


if __name__ == "__main__":
    unittest.main()
