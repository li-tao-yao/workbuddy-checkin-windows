"""Local regression server: never reads credentials or calls WorkBuddy."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import threading
import shutil


class Handler(BaseHTTPRequestHandler):
    redirects_followed = 0
    flow_claims = {}
    flow_status_calls = {}

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path.startswith('/flow-'):
            flow, endpoint = self.path[1:].split('/', 1)
            scenario = flow.removeprefix('flow-').rsplit('-', 1)[0]
            claims = Handler.flow_claims.get(flow, 0)
            if body != b'{}':
                self.send_error(422)
                return
            if endpoint == 'v2/plugin/auth/token/refresh':
                content = {'code': 0, 'data': {'accessToken': 'fixture-access', 'refreshToken': 'fixture-refresh'}}
                if scenario == 'rotated-cache' and self.headers.get('X-Refresh-Token') != 'fixture-new':
                    content = {'code': 401, 'msg': 'stale refresh credential'}
            elif endpoint == 'billing/meter/checkin-status':
                Handler.flow_status_calls[flow] = Handler.flow_status_calls.get(flow, 0) + 1
                content = {'code': 0, 'data': {
                    'active': scenario not in ['inactive', 'stale-status', 'status-inactive-success'],
                    'today_checked_in': scenario == 'already' or (claims > 0 and scenario == 'success'),
                    'streak_days': 2,
                }}
            elif endpoint == 'billing/meter/daily-checkin':
                Handler.flow_claims[flow] = claims + 1
                if scenario == 'inactive':
                    content = {'code': 10003, 'msg': 'activity ended'}
                elif scenario in ['already', 'stale-status', 'rotated-cache']:
                    content = {'code': 10001, 'msg': 'already claimed'}
                elif scenario == 'ineligible':
                    content = {'code': 10002, 'msg': 'ineligible'}
                elif scenario == 'no-credit':
                    content = {'code': 0, 'data': {}}
                else:
                    content = {'code': 0, 'data': {'credit': 100, 'streak_days': 2}}
            else:
                self.send_error(404)
                return
            data = json.dumps(content).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if body != b'{}' or self.headers.get('X-Test-Header') != 'local-test':
            self.send_error(422)
            return
        status = 200
        content = {'code': 0, 'data': {'credit': 100, 'streak_days': 2}}
        if self.path == '/already':
            status, content = 400, {'code': 10001, 'msg': '\u4eca\u5929\u5df2\u7b7e\u5230'}
        elif self.path == '/ineligible':
            status, content = 400, {'code': 10002, 'msg': 'ineligible'}
        elif self.path == '/inactive':
            status, content = 400, {'code': 10003, 'msg': 'inactive'}
        elif self.path == '/unauthorized':
            status, content = 401, {'code': 401, 'msg': 'unauthorized'}
        elif self.path == '/empty':
            content = b''
        elif self.path == '/html':
            status, content = 502, b'<html>gateway error</html>'
        elif self.path == '/invalid-json':
            content = b'{invalid'
        elif self.path == '/missing-code':
            content = {'data': {}}
        elif self.path == '/null':
            content = None
        elif self.path == '/server-error':
            status = 503
        elif self.path == '/redirect':
            status = 302
        elif self.path == '/redirect-target':
            Handler.redirects_followed += 1
        data = content if isinstance(content, bytes) else json.dumps(content, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        if status == 302:
            self.send_header('Location', '/redirect-target')
        self.end_headers()
        self.wfile.write(data)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        engines = [shutil.which(name) for name in ('pwsh', 'powershell')]
        if not any(engines):
            raise SystemExit('PowerShell is required')
        for shell_index, shell in enumerate(filter(None, engines)):
            result = subprocess.run([
                shell, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', str(Path(__file__).with_name('test-wb-http.ps1')),
                '-TestBaseUrl', f'http://127.0.0.1:{server.server_port}',
            ], capture_output=True, encoding='utf-8', errors='replace', timeout=50)
            print(result.stdout, end='')
            if result.returncode:
                print(result.stderr)
                raise SystemExit(result.returncode)
            test_root = Path(__file__).resolve().parent
            with tempfile.TemporaryDirectory(prefix='.wb-test-', dir=test_root) as tmp:
                tmp_path = Path(tmp).resolve()
                assert tmp_path.is_relative_to(test_root)
                auth_path = tmp_path / 'fixture-auth.json'
                auth_path.write_text(json.dumps({'account': {'uid': 'fixture-user'}, 'auth': {'refreshToken': 'fixture-refresh'}}), encoding='utf-8')
                close_test = subprocess.run([
                    shell, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-File', str(test_root / 'test-wb-close.ps1'), '-TestDirectory', str(tmp_path),
                ], capture_output=True, encoding='utf-8', errors='replace', timeout=25)
                print(close_test.stdout, end='')
                if close_test.returncode:
                    print(close_test.stderr)
                    raise SystemExit(close_test.returncode)
                for scenario in ['inactive', 'already', 'success', 'stale-status', 'status-inactive-success', 'ineligible', 'no-credit', 'rotated-cache', 'check-only']:
                    flow = f'flow-{scenario}-{shell_index}'
                    state_path = tmp_path / f'{scenario}-state.json'
                    log_path = tmp_path / f'{scenario}.log'
                    if scenario == 'rotated-cache':
                        os.utime(auth_path, (1577836800, 1577836800))
                        state_path.write_text(json.dumps({'uid': 'fixture-user', 'refreshToken': 'fixture-new',
                                                         'lastRun': '2021-01-01 00:00:00'}), encoding='utf-8')
                    base_url = f'http://127.0.0.1:{server.server_port}/{flow}'
                    template = (test_root.parent / 'wb-daily-checkin.ps1').read_text(encoding='utf-8-sig')
                    for host in ('https://www.workbuddy.cn', 'https://www.codebuddy.cn'):
                        template = template.replace("'" + host + "'", "'" + base_url + "'")
                    runner = tmp_path / 'wb-daily-checkin.ps1'
                    runner.write_text(template, encoding='utf-8-sig')
                    for name in ('wb-auth-path.ps1', 'wb-cache.ps1'):
                        shutil.copyfile(test_root.parent / name, tmp_path / name)
                    result = subprocess.run([
                        shell, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                        '-File', str(runner),
                        '-AuthInfoFile', str(auth_path), '-StateFile', str(state_path),
                        '-LogFile', str(log_path),
                        '-NoClose', '-TimeoutSec', '4',
                        *(['-CheckOnly'] if scenario == 'check-only' else []),
                    ], capture_output=True, encoding='utf-8', errors='replace', timeout=25)
                    expected_result = ('checked' if scenario == 'check-only' else
                                       'error' if scenario in ['no-credit', 'ineligible'] else
                                       'already' if scenario in ['stale-status', 'rotated-cache'] else
                                       'success' if scenario == 'status-inactive-success' else scenario)
                    expected_exit = 1 if expected_result == 'error' else 0
                    expected_claims = 0 if scenario == 'check-only' else 1
                    state = json.loads(state_path.read_text(encoding='utf-8-sig'))
                    if (result.returncode != expected_exit or state['lastResult'] != expected_result
                            or Handler.flow_claims.get(flow, 0) != expected_claims):
                        raise SystemExit(f'FAIL full-script flow: {scenario}, exit={result.returncode}, result={state["lastResult"]}')
                    if not state['refreshToken'].startswith('dpapi:') or 'fixture-refresh' in state_path.read_text(encoding='utf-8-sig'):
                        raise SystemExit('FAIL private cache protection')
                    if expected_result == 'success' and state['lastCredit'] != 100:
                        raise SystemExit('FAIL credit not recorded')
                    if expected_result == 'already' and state['lastCredit'] != 0:
                        raise SystemExit('FAIL already claimed reported new credits')
                    if Handler.flow_status_calls.get(flow, 0) != (1 if scenario == 'check-only' else 0):
                        raise SystemExit('FAIL stale status API consulted')
                    if scenario == 'inactive' and state['errorCount'] != 0:
                        raise SystemExit('FAIL inactive activity counted as failure')
                    log_text = log_path.read_text(encoding='utf-8-sig')
                    if any(token in log_text for token in ['fixture-access', 'fixture-refresh', 'fixture-new']):
                        raise SystemExit('FAIL credential appeared in log')
                    print(f'PASS full-script {scenario}, claims={expected_claims}, exit={expected_exit}')
        if Handler.redirects_followed:
            raise SystemExit('FAIL: followed a redirect')
        print('PASS no credential-bearing redirect followed')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
