#!/usr/bin/env python3
"""A tiny canned-body HTTP server standing in for the Verging Memory CI API.

Reads its script from $MOCK_DIR/scenario.json:
  receipt        the 202 body for POST /v1/releases
  receipt_code   optional, defaults to 202
  statuses       list of status bodies for GET /v1/releases/{id},
                 served in order, last one sticky
  status_by_id   optional map of release id to its own status list
  report         the body for GET /v1/releases/{id}/report
  report_by_id   optional map of release id to its own report body

Every request is appended to $MOCK_DIR/requests.log as one JSON line.
The chosen port is written to $MOCK_DIR/port.
"""
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

MOCK_DIR = os.environ["MOCK_DIR"]


def load_scenario():
    with open(os.path.join(MOCK_DIR, "scenario.json")) as f:
        return json.load(f)


def bump(name):
    path = os.path.join(MOCK_DIR, name + ".count")
    n = 0
    if os.path.exists(path):
        raw = open(path).read().strip()
        n = int(raw) if raw else 0
    n += 1
    with open(path, "w") as f:
        f.write(str(n))
    return n


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _record(self, body):
        with open(os.path.join(MOCK_DIR, "requests.log"), "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "body": body}) + "\n")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        self._record(body)
        sc = load_scenario()
        if self.path == "/v1/releases":
            self._send(sc.get("receipt_code", 202), sc["receipt"])
        else:
            self._send(404, {"error": "unknown path", "fix": "check the path"})

    def do_GET(self):
        self._record("")
        sc = load_scenario()
        parts = self.path.strip("/").split("/")
        if len(parts) >= 3 and parts[0] == "v1" and parts[1] == "releases":
            rid = parts[2]
            if len(parts) == 4 and parts[3] == "report":
                reports = sc.get("report_by_id", {})
                if rid in reports:
                    self._send(200, reports[rid])
                elif "report" in sc:
                    self._send(200, sc["report"])
                else:
                    self._send(409, {"error": "the release has not finished",
                                     "fix": "poll the status URL and retry"})
                return
            if len(parts) == 3:
                statuses = sc.get("status_by_id", {}).get(rid) or sc.get("statuses", [])
                if not statuses:
                    self._send(404, {"error": "no such release",
                                     "fix": "compare the id against your receipt"})
                    return
                n = bump("status-" + rid)
                idx = min(n, len(statuses)) - 1
                self._send(200, statuses[idx])
                return
        self._send(404, {"error": "unknown path", "fix": "check the path"})


def main():
    srv = HTTPServer(("127.0.0.1", 0), Handler)
    with open(os.path.join(MOCK_DIR, "port"), "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()


if __name__ == "__main__":
    main()
