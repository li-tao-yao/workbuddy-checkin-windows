"""Exercise the real agent entry points with disposable Windows profiles."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


repo = Path(__file__).resolve().parents[1]
secret = "synthetic-for-test-only"


def run(engine, script, env, *args):
    return subprocess.run(
        [engine, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
         "-File", str(repo / script), *args], cwd=repo, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=25,
    )


def check(engine):
    with tempfile.TemporaryDirectory(prefix="wb profile ") as tmp:
        local, roaming = Path(tmp, "local"), Path(tmp, "roaming")
        env = dict(os.environ, LOCALAPPDATA=str(local), APPDATA=str(roaming))
        suffix = Path("CodeBuddyExtension", "Data", "Public", "auth")
        desktop = local / suffix / "workbuddy-desktop.info"
        companion = roaming / suffix / "Tencent-Cloud.coding-copilot.info"
        desktop.parent.mkdir(parents=True)
        companion.parent.mkdir(parents=True)

        def put(path, uid, token):
            path.write_text(json.dumps({"account": {"uid": uid},
                                        "auth": {"refreshToken": token}}), encoding="utf-8")

        def expect(route, reason, exit_code=0):
            p = run(engine, "Diagnose.ps1", env, "-Json")
            assert p.returncode == exit_code and json.loads(p.stdout) == {
                "route": route, "reason": reason}, reason
            assert secret.encode() not in p.stdout

        expect("Unavailable", "LoginRequired", 1)
        put(desktop, "account-a", secret)
        expect("WindowsTask", "TextLogin")
        put(desktop, "account-a", {"$wbEncrypted": 1, "envelope": "fixture"})
        expect("ClientTask", "EncryptedOnly")
        put(companion, "account-b", secret)
        expect("ClientTask", "EncryptedOnly")
        name = "WbDryRun-" + uuid.uuid4().hex
        assert run(engine, "Install.ps1", env, "-WhatIf", "-TaskName", name).returncode != 0
        put(companion, "account-a", secret)
        expect("WindowsTask", "SameAccountCompanion")
        preview = run(engine, "Install.ps1", env, "-NoClose", "-WhatIf", "-TaskName", name)
        assert preview.returncode == 0 and b"16:00" in preview.stdout
        assert secret.encode() not in preview.stdout
        put(desktop, "", {"$wbEncrypted": 1})
        expect("ClientTask", "EncryptedOnly")
        put(desktop, "account-a", {"unsupported": 2})
        expect("Unavailable", "UnknownFormat", 1)
        desktop.write_text("{broken", encoding="utf-8")
        expect("Unavailable", "Unreadable", 1)
    print(f"PASS login selection and agent install preview: {engine}")


if __name__ == "__main__":
    engines = list(filter(None, (shutil.which("pwsh"), shutil.which("powershell"))))
    if not engines:
        raise SystemExit("Windows PowerShell or pwsh required")
    for engine in engines:
        check(engine)
