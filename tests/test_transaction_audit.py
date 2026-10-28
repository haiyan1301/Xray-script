"""Install-transaction fault injection; no host firewall or services are used."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

from test_regressions import ROOT, definitions


class ProtocolTransactionAuditTests(unittest.TestCase):
    def run_failed_install(self, *, removal_fails=False):
        with tempfile.TemporaryDirectory(prefix="xray-install-rollback-") as temp:
            work = Path(temp)
            config = work / "config.json"
            runtime = work / "runtime.json"
            events = work / "events"
            old_rule = {
                "feature": "xray", "backend": "ufw", "port": 443,
                "protocol": "tcp", "ipv4": False, "ipv6": False,
            }
            new_rule = old_rule | {"port": 8443}
            old = {"nginx": {}, "xray": {"tag": "Vision", "firewallRules": [old_rule]}}
            config.write_text(json.dumps(old) + "\n")
            old_runtime = '{"inbounds":[{"port":443}]}\n'
            runtime.write_text(old_runtime)
            env = os.environ | {
                "TEST_CONFIG": str(config), "TEST_RUNTIME": str(runtime),
                "TEST_EVENTS": str(events), "TEST_RULE": json.dumps(new_rule),
                "TEST_REMOVE_FAILS": str(int(removal_fails)),
            }
            script = (
                f"source {shlex.quote(str(ROOT / 'lib/common.sh'))}\n"
                f"source {shlex.quote(str(ROOT / 'lib/protocols.sh'))}\n"
                + definitions("core/main.sh", "restore_protocol_snapshot", "rollback_protocol_install", "install_protocol")
                + r'''
SCRIPT_CONFIG_PATH="$TEST_CONFIG"
XRAY_RUNTIME_CONFIG_PATH="$TEST_RUNTIME"
CUR_FILE=main
sync() { :; }
t() { printf '%s' "$1"; }
create_nginx_artifact_journal() { :; }
cleanup_nginx_artifact_journal() { :; }
firewall_rule_remove() {
    printf 'remove:%s\n' "$(jq -r .port <<<"$1")" >>"$TEST_EVENTS"
    [[ "$TEST_REMOVE_FAILS" == 0 ]]
}
firewall_rule_restore() {
    printf 'restore:%s\n' "$(jq -r .port <<<"$1")" >>"$TEST_EVENTS"
}
exec_handler() {
    case "$1" in
    --script-config|--install) return 0 ;;
    --xray-config)
        local next
        next="$(jq --argjson rule "$TEST_RULE" '.xray.firewallRules += [$rule] | .xray.port = 8443' "$TEST_CONFIG")" || return 1
        write_config "$next" "$TEST_CONFIG" || return 1
        printf '%s\n' '{"inbounds":[{"port":8443}]}' >"$TEST_RUNTIME"
        ;;
    --restart) return 1 ;;
    --recover-runtime) printf 'recover\n' >>"$TEST_EVENTS" ;;
    *) return 1 ;;
    esac
}
install_protocol Vision
'''
            )
            result = subprocess.run(
                ["bash", "-c", script], cwd=ROOT, env=env,
                text=True, capture_output=True, timeout=20,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(runtime.read_text(), old_runtime)
            actual = json.loads(config.read_text())
            self.assertNotIn("port", actual["xray"])
            self.assertEqual(
                actual["xray"]["firewallRules"],
                [old_rule, new_rule] if removal_fails else [old_rule],
            )
            self.assertEqual(
                events.read_text().splitlines(),
                ["remove:8443", "restore:8443", "recover"] if removal_fails
                else ["remove:8443", "recover"],
            )
            self.assertFalse(list(work.glob("*.install.*")))
            return result

    def test_restart_failure_removes_only_new_owned_ports(self):
        self.run_failed_install()

    def test_firewall_failure_preserves_ownership_for_future_cleanup(self):
        result = self.run_failed_install(removal_fails=True)
        self.assertIn("ownership records were retained", result.stderr)


class ConfigurationGenerationAuditTests(unittest.TestCase):
    def run_handler(self, body, *, fail_option="", mode="Vision"):
        with tempfile.TemporaryDirectory(prefix="xray-generator-failure-") as temp:
            work = Path(temp)
            config = work / "config.json"
            config.write_bytes((ROOT / "config.json").read_bytes())
            env = os.environ | {
                "SCRIPT_CONFIG_PATH_OVERRIDE": str(config),
                "XRAY_CONFIG_PATH_OVERRIDE": str(work / "runtime.json"),
                "TEST_FAIL_OPTION": fail_option, "TEST_MODE": mode,
                "TEST_WORK": str(work),
            }
            script = f"source {shlex.quote(str(ROOT / 'core/handler.sh'))}\n" + r'''
sync() { :; }
load_i18n
CONFIG_DATA['uuid']='11111111-1111-4111-8111-111111111111'
CONFIG_DATA['fallback']='22222222-2222-4222-8222-222222222222'
exec_generate() {
    [[ "$1" != "$TEST_FAIL_OPTION" ]] || return 23
    case "$1" in
    --uuid) printf '%s\n' '11111111-1111-4111-8111-111111111111' ;;
    --target) printf '%s\n' 'www.example.com' ;;
    --server-names) printf '%s\n' '["www.example.com"]' ;;
    --short-ids) printf '%s\n' '["0123456789abcdef"]' ;;
    --port) printf '%s\n' '12345' ;;
    --path) printf '%s\n' '/test/' ;;
    *) printf '%s\n' 'secret' ;;
    esac
}
''' + body
            result = subprocess.run(
                ["bash", "-c", script], cwd=ROOT, env=env,
                capture_output=True, text=True, timeout=20,
            )
            return result, json.loads(config.read_text())

    def test_single_node_generation_failures_abort_configuration(self):
        for mode, option in [
            ("Vision", "--target"), ("Vision", "--server-names"),
            ("Vision", "--short-ids"), ("XHTTP", "--path"),
            ("Trojan", "--password"), ("mKCP", "--password"),
            ("mKCP", "--port"), ("hy2", "--hy2-auth"),
            ("ss2022", "--ss2022-key"),
        ]:
            with self.subTest(mode=mode, option=option):
                result, config = self.run_handler(
                    'handler_script_config "$TEST_MODE"', fail_option=option, mode=mode,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotEqual(config["xray"]["tag"], mode)

    def test_multi_node_generation_failures_are_not_hidden_by_local(self):
        for mode, option in [
            ("Vision", "--target"), ("Vision", "--server-names"),
            ("Vision", "--short-ids"), ("XHTTP", "--path"),
            ("Trojan", "--password"), ("mKCP", "--password"),
            ("hy2", "--hy2-auth"), ("ss2022", "--ss2022-key"),
        ]:
            with self.subTest(mode=mode, option=option):
                result, _ = self.run_handler(
                    'build_multi_node_json "$TEST_MODE" 1 8443', fail_option=option, mode=mode,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_single_mkcp_retries_reserved_api_port(self):
        result, config = self.run_handler(r'''
exec_generate() {
    case "$1" in
    --port)
        if [[ ! -e "$TEST_WORK/generated-once" ]]; then
            touch "$TEST_WORK/generated-once"
            printf '32768\n'
        else
            printf '12345\n'
        fi
        ;;
    --uuid) printf '11111111-1111-4111-8111-111111111111\n' ;;
    --password) printf 'seed\n' ;;
    esac
}
handler_script_config mKCP
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(config["xray"]["port"], 12345)

    def test_multi_port_generation_failure_does_not_return_empty_port(self):
        result, _ = self.run_handler(
            "generate_unique_multi_port '' mKCP", fail_option="--port",
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")

    def test_repeated_port_conflicts_abort_instead_of_looping_forever(self):
        result, _ = self.run_handler(r'''
t() { printf '%s' "$1"; }
exec_generate() { printf '32768\n'; }
generate_unique_multi_port '' mKCP
''')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Unable to generate an unused Xray port", result.stderr)


class BinaryInstallServiceRollbackTests(unittest.TestCase):
    def test_initial_service_query_error_never_runs_installer(self):
        with tempfile.TemporaryDirectory(prefix="xray-query-before-install-") as temp:
            work = Path(temp)
            config = work / "config.json"
            config.write_bytes((ROOT / "config.json").read_bytes())
            before_config = config.read_bytes()
            binary = work / "xray"
            binary.write_text("#!/usr/bin/env bash\nprintf 'Xray 1.8.24 old\\n'\n")
            binary.chmod(0o755)
            before_binary = binary.read_bytes()
            env = os.environ | {
                "SCRIPT_CONFIG_PATH_OVERRIDE": str(config), "XRAY_BIN_PATH_OVERRIDE": str(binary),
                "XRAY_CONFIG_PATH_OVERRIDE": str(work / "runtime.json"), "TEST_WORK": str(work),
            }
            script = f"source {shlex.quote(str(ROOT / 'core/handler.sh'))}\n" + r'''
sync() { :; }
load_i18n
SCRIPT_CONFIG="$(jq '.xray.githubProxy = "n"' <<<"$SCRIPT_CONFIG")"
ensure_service_users() { :; }
systemctl() { return 1; }
fetch_xray_install_script() { printf 'touch "$TEST_WORK/installer-executed"\n'; }
handler_install v26.10.21 y y
'''
            result = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((work / "installer-executed").exists())
            self.assertEqual(binary.read_bytes(), before_binary)
            self.assertEqual(config.read_bytes(), before_config)
            self.assertFalse(list(work.glob(".xray-install.*")))
            self.assertFalse(list(work.glob("config.json.version.*")))

    def test_uncertain_service_query_preserves_binary_recovery_copy(self):
        for query_status in (1, 4):
            with self.subTest(query_status=query_status):
                with tempfile.TemporaryDirectory(prefix="xray-query-error-") as temp:
                    work = Path(temp)
                    binary = work / "xray"
                    binary.write_text("replacement")
                    snapshot = work / "snapshot"
                    snapshot.mkdir()
                    (snapshot / "xray").write_text("original")
                    script = definitions(
                        "core/handler.sh", "restore_xray_binary_snapshot", "restore_xray_install_snapshot",
                    ) + f'''
XRAY_BIN_PATH={shlex.quote(str(binary))}
systemctl() {{ return {query_status}; }}
restore_xray_install_snapshot {shlex.quote(str(snapshot))} 1 1 1
'''
                    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=10)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(binary.read_text(), "replacement")
                    self.assertEqual((snapshot / "xray").read_text(), "original")
                    self.assertIn("could not determine", result.stderr)

    def test_missing_first_install_unit_allows_partial_binary_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="xray-missing-unit-") as temp:
            work = Path(temp)
            binary = work / "xray"
            binary.write_text("partial")
            snapshot = work / "snapshot"
            snapshot.mkdir()
            script = definitions(
                "core/handler.sh", "restore_xray_binary_snapshot", "restore_xray_install_snapshot",
            ) + f'''
XRAY_BIN_PATH={shlex.quote(str(binary))}
systemctl() {{ [[ "$*" != *is-active* ]] || return 4; return 1; }}
restore_xray_install_snapshot {shlex.quote(str(snapshot))} 0 0 0
'''
            result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(binary.exists())
            self.assertFalse(snapshot.exists())

    def test_all_install_failures_restore_active_and_enabled_state(self):
        for failure in ("installer", "mismatch", "commit"):
            for active, enabled in ((True, True), (False, False), (True, False), (False, True)):
                with self.subTest(failure=failure, active=active, enabled=enabled):
                    self.run_failure(failure, active, enabled)

    def run_failure(self, failure, active, enabled):
        with tempfile.TemporaryDirectory(prefix="xray-binary-service-") as temp:
            work = Path(temp)
            config = work / "config.json"
            state = json.loads((ROOT / "config.json").read_text())
            state["language"] = "en"
            state["xray"].update(version="v1.8.24", githubProxy="n")
            config.write_text(json.dumps(state) + "\n")
            before_config = config.read_bytes()
            binary = work / "xray"
            binary.write_text("#!/usr/bin/env bash\nprintf 'Xray 1.8.24 old\\n'\n")
            binary.chmod(0o755)
            before_binary = binary.read_bytes()
            for name, present in (("active", active), ("enabled", enabled)):
                if present:
                    (work / name).touch()
            installer = work / "installer.sh"
            installer.write_text(r'''#!/usr/bin/env bash
touch "$TEST_WORK/installer-executed"
printf '#!/usr/bin/env bash\nprintf "Xray %s replacement\\n"\n' "${TEST_NEW_VERSION}" >"$XRAY_BIN_PATH_OVERRIDE"
chmod 755 "$XRAY_BIN_PATH_OVERRIDE"
# Model upstream failing after stopping the daemon, or returning a running but
# invalid replacement that fails our version check/metadata commit.
if [[ "$TEST_FAILURE" == installer ]]; then
    rm -f "$TEST_WORK/active" "$TEST_WORK/enabled"
    exit 23
fi
touch "$TEST_WORK/active" "$TEST_WORK/enabled"
''')
            env = os.environ | {
                "SCRIPT_CONFIG_PATH_OVERRIDE": str(config),
                "XRAY_BIN_PATH_OVERRIDE": str(binary),
                "XRAY_CONFIG_PATH_OVERRIDE": str(work / "runtime.json"),
                "TEST_WORK": str(work), "TEST_INSTALLER": str(installer),
                "TEST_FAILURE": failure,
                "TEST_NEW_VERSION": "0.0.0" if failure == "mismatch" else "26.10.21",
            }
            script = f"source {shlex.quote(str(ROOT / 'core/handler.sh'))}\n" + r'''
sync() { :; }
load_i18n
ensure_service_users() { :; }
fetch_xray_install_script() { cat "$TEST_INSTALLER"; }
systemctl() {
    local action='' argument
    for argument in "$@"; do
        [[ "$argument" == -* ]] && continue
        action="$argument"
        break
    done
    printf '%s\n' "$action" >>"$TEST_WORK/events"
    case "$action" in
    is-active) [[ -f "$TEST_WORK/active" ]] || return 3 ;;
    is-enabled) [[ -f "$TEST_WORK/enabled" ]] ;;
    start)
        "$XRAY_BIN_PATH_OVERRIDE" -version >>"$TEST_WORK/started-version"
        touch "$TEST_WORK/active"
        ;;
    stop) rm -f "$TEST_WORK/active" ;;
    enable) touch "$TEST_WORK/enabled" ;;
    disable) rm -f "$TEST_WORK/enabled" ;;
    reset-failed) return 0 ;;
    *) return 1 ;;
    esac
}
mv() {
    if [[ "$TEST_FAILURE" == commit && "$*" == *config.json.version.* && "${@: -1}" == "$SCRIPT_CONFIG_PATH_OVERRIDE" ]]; then
        return 1
    fi
    command mv "$@"
}
handler_install v26.10.21 y y
'''
            result = subprocess.run(
                ["bash", "-c", script], cwd=ROOT, env=env,
                capture_output=True, text=True, timeout=20,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((work / "installer-executed").exists())
            self.assertEqual(binary.read_bytes(), before_binary)
            self.assertEqual(config.read_bytes(), before_config)
            self.assertEqual((work / "active").exists(), active)
            self.assertEqual((work / "enabled").exists(), enabled)
            if active:
                self.assertEqual((work / "started-version").read_text(), "Xray 1.8.24 old\n")
            else:
                self.assertFalse((work / "started-version").exists())
            self.assertFalse(list(work.glob(".xray-install.*")))
            self.assertFalse(list(work.glob("config.json.version.*")))


class RuntimeValidationLogTests(unittest.TestCase):
    def check_log_validation(self, entrypoint, validation_fails=False):
        with tempfile.TemporaryDirectory(prefix="xray-log-validation-") as temp:
            work = Path(temp)
            config = work / "script.json"
            runtime = work / "runtime.json"
            config.write_text('{"old":"script"}\n')
            runtime.write_text('{"old":"runtime"}\n')
            before_config = config.read_bytes()
            before_runtime = runtime.read_bytes()
            content = {
                "log": {"access": str(work / "access.log"), "error": str(work / "error.log"), "loglevel": "warning"},
                "certificateFile": "certs/relative-fullchain.pem",
                "inbounds": [],
            }
            candidate = work / "candidate.json"
            candidate.write_text(json.dumps(content))
            env = os.environ | {
                "SCRIPT_CONFIG_PATH_OVERRIDE": str(config), "XRAY_CONFIG_PATH_OVERRIDE": str(runtime),
                "TEST_CANDIDATE": str(candidate), "TEST_WORK": str(work),
                "TEST_VALIDATION_FAILS": str(int(validation_fails)),
            }
            script = f"source {shlex.quote(str(ROOT / 'core/handler.sh'))}\n" + r'''
sync() { :; }
id() { return 1; }
xray() {
    [[ "$1 $2 $3" == 'run -test -c' ]] || return 1
    # Model the core's real side effect when test mode receives file log paths.
    local log_path
    while IFS= read -r log_path; do
        [[ "$log_path" == none ]] || : >"$log_path"
    done < <(jq -r '.log.access, .log.error' "$4")
    cp "$4" "$TEST_WORK/validated.json"
    stat -c '%a' "$4" >"$TEST_WORK/validation-mode"
    dirname "$4" >"$TEST_WORK/validation-dir"
    [[ "$TEST_VALIDATION_FAILS" == 0 ]]
}
''' + (
                'write_xray_runtime_config "$(cat "$TEST_CANDIDATE")"\n'
                if entrypoint == "write" else
                'commit_xray_and_script_config "$(cat "$TEST_CANDIDATE")" \'{"new":"script"}\'\n'
            )
            result = subprocess.run(["bash", "-c", script], env=env, cwd=ROOT, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode == 0, not validation_fails, result.stdout + result.stderr)
            self.assertFalse((work / "access.log").exists())
            self.assertFalse((work / "error.log").exists())
            validated = json.loads((work / "validated.json").read_text())
            self.assertEqual(validated["log"], content["log"] | {"access": "none", "error": "none"})
            self.assertEqual(validated["certificateFile"], content["certificateFile"])
            self.assertEqual((work / "validation-mode").read_text().strip(), "600")
            self.assertEqual(Path((work / "validation-dir").read_text().strip()), work)
            self.assertFalse(list(work.glob("*.validate.*")))
            self.assertFalse(list(work.glob("*.tmp.*")))
            if validation_fails:
                self.assertEqual(runtime.read_bytes(), before_runtime)
                self.assertEqual(config.read_bytes(), before_config)
            else:
                self.assertEqual(json.loads(runtime.read_text()), content)

    def test_both_commit_paths_validate_without_opening_configured_logs(self):
        for entrypoint in ("write", "combined"):
            with self.subTest(entrypoint=entrypoint):
                self.check_log_validation(entrypoint)

    def test_validation_failure_cleans_private_copy_and_preserves_live_configs(self):
        for entrypoint in ("write", "combined"):
            with self.subTest(entrypoint=entrypoint):
                self.check_log_validation(entrypoint, validation_fails=True)


if __name__ == "__main__":
    unittest.main()
