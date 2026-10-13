#!/usr/bin/python3
"""Throwaway test server for computer_act: serves page.html on 127.0.0.1:PORT, appends POST /log bodies to LOGFILE."""
import http.server, sys, pathlib
PORT, LOGFILE = int(sys.argv[1]), sys.argv[2]
HERE = pathlib.Path(__file__).parent
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = (HERE / "page.html").read_bytes(); self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        open(LOGFILE, "a").write(self.rfile.read(int(self.headers["Content-Length"])).decode() + "\n")
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
