import json, os, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("RUNNER_TOKEN", "")
MAX_OUT = 100_000

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/exec":
            return self._send(404, {"error": "not found"})
        if TOKEN and self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self._send(401, {"error": "unauthorized"})
        length = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(length))
            cmd = req["cmd"]
            timeout = min(int(req.get("timeout", 10)), 60)
        except Exception:
            return self._send(400, {"error": "bad request"})
        try:
            p = subprocess.run(cmd, shell=True, capture_output=True,
                               text=True, timeout=timeout, cwd="/tmp")
            self._send(200, {"exit_code": p.returncode,
                             "stdout": p.stdout[:MAX_OUT],
                             "stderr": p.stderr[:MAX_OUT]})
        except subprocess.TimeoutExpired:
            self._send(200, {"exit_code": -1, "stdout": "", "stderr": "timeout"})

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
