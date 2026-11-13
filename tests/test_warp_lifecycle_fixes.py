"""WARP readiness and migration regression tests; Docker is a local model."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

from test_service_audit import ROOT, definitions


DOCKER_MODEL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
work = pathlib.Path(os.environ['TEST_WORK'])
path = work / 'docker-state.json'
state = json.loads(path.read_text())
args = sys.argv[1:]
with (work / 'commands').open('a') as log:
    log.write(' '.join(args) + '\n')
containers, images = state['containers'], state['images']
failure = os.environ.get('TEST_FAILURE', '')
def save(): path.write_text(json.dumps(state))
def fail(code=42): sys.exit(code)
if args[0] == 'info': pass
elif args[0] == 'inspect':
    name = args[-1]
    if name not in containers: fail()
    c = containers[name]
    fmt = args[1] if len(args) > 2 else ''
    if fmt == '--format={{.Image}}': print(c['image'])
    elif fmt == '--format={{.State.Status}}': print('running' if c['running'] else 'exited')
    elif fmt == '--format={{.State.Running}}': print(str(c['running']).lower())
    elif fmt == '--format={{.HostConfig.RestartPolicy.Name}}': print(c['restart'].split(':')[0])
    elif fmt == '--format={{.HostConfig.RestartPolicy.MaximumRetryCount}}': print(c['restart'].split(':')[1] if ':' in c['restart'] else '0')
elif args[:2] == ['image', 'inspect']:
    if args[-1] not in images: fail()
    if len(args) > 3: print(images[args[-1]])
elif args[:2] == ['image', 'rm']:
    images.pop(args[-1], None); save()
elif args[0] == 'tag':
    images[args[2]] = images.get(args[1], args[1]); save()
elif args[0] == 'run':
    name = next(a.split('=', 1)[1] for a in args if a.startswith('--name='))
    data = pathlib.Path(next(args[i+1] for i,a in enumerate(args) if a == '-v').split(':')[0])
    (data / 'reg.json').write_text('candidate wrote state')
    containers[name] = {'image': images[args[-1]], 'running': True, 'restart': 'unless-stopped'}
    save()
    if failure == 'run': fail()
elif args[0] == 'update':
    if failure == 'update' and args[-1] == 'warp' and args[1] == '--restart=no': fail()
    if failure == 'restore-policy' and args[1] == '--restart=unless-stopped': fail()
    containers[args[-1]]['restart'] = args[1].split('=',1)[1]; save()
elif args[0] == 'stop':
    if failure == 'stop': fail()
    containers[args[-1]]['running'] = False; save()
elif args[0] == 'start':
    if failure == 'restore-start': fail()
    containers[args[-1]]['running'] = True; save()
elif args[0] == 'rename':
    if failure == 'rename' and args[1] == 'warp': fail()
    containers[args[2]] = containers.pop(args[1]); save()
elif args[:2] == ['rm', '-f']:
    if failure == 'remove-candidate' and args[-1] == 'warp': fail()
    containers.pop(args[-1], None); save()
else: fail(98)
'''


class WarpLifecycleFixes(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-warp-fixes-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.env = os.environ | {"TEST_WORK": str(self.work), "PATH": str(self.bin) + ":" + os.environ["PATH"]}

    def bash(self, body, env=None):
        return subprocess.run(["bash", "-c", body], cwd=ROOT, env=self.env | (env or {}),
                              capture_output=True, text=True, errors="replace", timeout=15)

    def migration_body(self):
        names = ["_warp_container_state", "_warp_run_container", "_warp_container_uses_image",
                 "_warp_image_id", "_warp_tx_cleanup_backup_containers", "_warp_tx_cleanup_images",
                 "_warp_tx_cleanup_transaction_dir", "_warp_finish_transaction_cleanup",
                 "_warp_tx_restore_data", "_warp_recover_pending_transaction", "rollback_warp_reset",
                 "prepare_warp_reset", "commit_warp_reset", "_warp_migrate_container"]
        body = (ROOT / "lib/transaction.sh").read_text() + "\n" + definitions("service/docker.sh", *names)
        body += r'''
WARP_NAME=warp
WARP_IMAGE=latest
WARP_RESET_IMAGE=candidate
WARP_BACKUP_IMAGE=backup
WARP_BACKUP_RUNNING=old-running
WARP_BACKUP_STOPPED=old-stopped
DOCKER_DIR="${TEST_WORK}"
WARP_DIR="${TEST_WORK}/data"
WARP_TRANSACTION_DIR="${TEST_WORK}/transaction"
WARP_HOST=127.0.0.1
WARP_PORT=40001
docker_ready() { return 0; }
t() { printf '%s' "$1"; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
log_tip() { :; }
print_info() { :; }
wait_for_warp() {
    local count=0
    [[ ! -f "${TEST_WORK}/wait-count" ]] || read -r count <"${TEST_WORK}/wait-count"
    count=$((count + 1))
    printf '%s\n' "$count" >"${TEST_WORK}/wait-count"
    case "${TEST_FAILURE:-}" in ready|restore-policy|restore-start|remove-candidate) return 1 ;; esac
    [[ "${TEST_FAILURE:-}" != commit || $count -lt 2 ]] || return 1
    printf '127.0.0.1\n'
}
_warp_migrate_container 0
'''
        return body

    def setup_migration(self, *, running=True, same_image=False):
        (self.bin / "docker").write_text(DOCKER_MODEL)
        (self.bin / "docker").chmod(0o755)
        old_image = "new-id" if same_image else "old-id"
        old = {"image": old_image, "running": running, "restart": "unless-stopped" if running else "no"}
        (self.work / "docker-state.json").write_text(json.dumps({"containers": {"warp": old}, "images": {"latest": "new-id"}}))
        (self.work / "data").mkdir(exist_ok=True)
        (self.work / "data/reg.json").write_text("original identity")
        return old

    def test_failed_migration_restores_container_image_policy_and_identity(self):
        for failure in ["update", "stop", "rename", "run", "ready", "commit"]:
            for running in [True, False]:
                if failure == "stop" and not running:
                    continue
                with self.subTest(failure=failure, running=running):
                    (self.work / "wait-count").write_text("0\n")
                    old = self.setup_migration(running=running)
                    result = self.bash(self.migration_body(), {"TEST_FAILURE": failure})
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    state = json.loads((self.work / "docker-state.json").read_text())
                    self.assertEqual(state["containers"], {"warp": old}, result.stderr)
                    self.assertEqual((self.work / "data/reg.json").read_text(), "original identity")
                    if failure not in ["update", "stop", "rename"]:
                        self.assertEqual(state["images"]["latest"], "old-id")
                    self.assertFalse((self.work / "transaction").exists())

    def test_same_image_migration_early_failure_never_deletes_original(self):
        old = self.setup_migration(same_image=True)
        result = self.bash(self.migration_body(), {"TEST_FAILURE": "update"})
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((self.work / "docker-state.json").read_text())
        self.assertEqual(state["containers"], {"warp": old}, result.stderr)
        self.assertNotIn("rm -f warp", (self.work / "commands").read_text())

    def test_successful_migration_discards_backups_only_after_readiness(self):
        self.setup_migration()
        result = self.bash(self.migration_body())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), "127.0.0.1")
        state = json.loads((self.work / "docker-state.json").read_text())
        self.assertEqual(state["containers"], {"warp": {"image": "new-id", "running": True, "restart": "unless-stopped"}})
        self.assertEqual(state["images"], {"latest": "new-id"})
        self.assertFalse((self.work / "transaction").exists())

    def test_interrupted_rollback_can_retry_without_deleting_restored_container(self):
        for failure in ["restore-policy", "restore-start", "remove-candidate"]:
            with self.subTest(failure=failure):
                old = self.setup_migration(same_image=True)
                failed = self.bash(self.migration_body(), {"TEST_FAILURE": failure})
                self.assertNotEqual(failed.returncode, 0)
                self.assertTrue((self.work / "transaction").exists())
                recovery = self.migration_body().rsplit("_warp_migrate_container 0", 1)[0]
                recovered = self.bash(recovery + "_warp_recover_pending_transaction\n")
                self.assertEqual(recovered.returncode, 0, recovered.stderr)
                state = json.loads((self.work / "docker-state.json").read_text())
                self.assertEqual(state["containers"], {"warp": old})
                self.assertEqual((self.work / "data/reg.json").read_text(), "original identity")
                self.assertFalse((self.work / "transaction").exists())

    def test_rollback_restores_absence_of_original_state_directory(self):
        old = self.setup_migration()
        shutil.rmtree(self.work / "data")
        result = self.bash(self.migration_body(), {"TEST_FAILURE": "ready"})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / "data").exists())
        state = json.loads((self.work / "docker-state.json").read_text())
        self.assertEqual(state["containers"], {"warp": old})
        self.assertFalse((self.work / "transaction").exists())

    def test_rollback_restores_on_failure_retry_count(self):
        old = self.setup_migration()
        state = json.loads((self.work / "docker-state.json").read_text())
        old["restart"] = "on-failure:7"
        state["containers"]["warp"] = old
        (self.work / "docker-state.json").write_text(json.dumps(state))
        result = self.bash(self.migration_body(), {"TEST_FAILURE": "ready"})
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((self.work / "docker-state.json").read_text())
        self.assertEqual(state["containers"], {"warp": old}, result.stderr)

    def test_enable_and_repair_use_migration_transaction(self):
        for entry in ["enable_warp", "repair_warp"]:
            body = definitions("service/docker.sh", entry) + r'''
WARP_NAME=warp
WARP_IMAGE=latest
docker_ready() { :; }
_warp_recover_pending_transaction() { :; }
build_warp() { :; }
_warp_container_state() { printf running; }
_warp_container_has_expected_runtime() { return 1; }
t() { printf '%s' "$1"; }
print_info() { :; }
log_info() { :; }
_warp_migrate_container() { touch "${TEST_WORK}/migrate-called"; return 42; }
docker() { printf '%s\n' "$*" >>"${TEST_WORK}/unexpected-docker"; return 99; }
''' + entry + "\n"
            result = self.bash(body)
            self.assertEqual(result.returncode, 42, result.stderr)
            self.assertTrue((self.work / "migrate-called").exists())
            self.assertFalse((self.work / "unexpected-docker").exists())

    def test_readiness_requires_live_container_health_and_host_endpoint(self):
        body = definitions("service/docker.sh", "_warp_container_ready") + r'''
WARP_NAME=warp
WARP_HOST=127.0.0.1
WARP_PORT="${TEST_PORT}"
cmd_exists() { command -v "$1" >/dev/null; }
docker() { return "${TEST_CONTAINER_HEALTH}"; }
timeout() {
    case " $* " in
        *" docker exec "*) return "${TEST_CONTAINER_HEALTH}" ;;
        *) return "${TEST_ENDPOINT_HEALTH}" ;;
    esac
}
_warp_container_ready
'''
        good = self.bash(body, {"TEST_PORT": "40001", "TEST_CONTAINER_HEALTH": "0", "TEST_ENDPOINT_HEALTH": "0"})
        self.assertEqual(good.returncode, 0, good.stderr)
        bad = self.bash(body, {"TEST_PORT": "40001", "TEST_CONTAINER_HEALTH": "1", "TEST_ENDPOINT_HEALTH": "0"})
        self.assertNotEqual(bad.returncode, 0)
        closed = self.bash(body, {"TEST_PORT": "40001", "TEST_CONTAINER_HEALTH": "0", "TEST_ENDPOINT_HEALTH": "1"})
        self.assertNotEqual(closed.returncode, 0)

    def test_container_health_rejects_stale_marker_and_each_failed_probe(self):
        probe = self.bin / "timeout"
        probe.write_text(r'''#!/usr/bin/env bash
case "$*" in
    *warp-cli*) printf 'Status update: %s\n' "${TEST_STATUS}"; exit "${TEST_CLI_EXIT}" ;;
    */40000*) exit "${TEST_PROXY_EXIT}" ;;
    */40001*) exit "${TEST_FORWARD_EXIT}" ;;
    *) exit 98 ;;
esac
''')
        probe.chmod(0o755)
        env = {"WARP_STATE_DIR": str(self.work), "TEST_STATUS": "Connected", "TEST_CLI_EXIT": "0",
               "TEST_PROXY_EXIT": "0", "TEST_FORWARD_EXIT": "0"}
        cases = [({}, True, True), ({}, False, False), ({"TEST_STATUS": "Disconnected"}, True, False),
                 ({"TEST_CLI_EXIT": "124"}, True, False), ({"TEST_PROXY_EXIT": "1"}, True, False),
                 ({"TEST_FORWARD_EXIT": "1"}, True, False)]
        for overrides, has_marker, expected in cases:
            with self.subTest(overrides=overrides, has_marker=has_marker):
                marker = self.work / "ready"
                if has_marker:
                    marker.touch()
                elif marker.exists():
                    marker.unlink()
                result = self.bash("bash config/cloudflare-warp/healthcheck.sh", env | overrides)
                self.assertEqual(result.returncode == 0, expected, result.stderr)


if __name__ == "__main__":
    unittest.main()
