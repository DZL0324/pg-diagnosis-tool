#!/usr/bin/env python3
import html
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

HTML_PAGE = """<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\" />
  <title>PG AWR Snapshot Tool</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 24px; }
    .grid { display: grid; grid-template-columns: 180px 1fr; gap: 8px; max-width: 640px; }
    label { font-weight: 600; }
    input { padding: 6px; }
    button { margin-top: 12px; padding: 8px 12px; }
    pre { background: #f5f5f5; padding: 12px; overflow: auto; }
    .hint { color: #666; font-size: 12px; }
  </style>
</head>
<body>
  <h1>PG AWR Snapshot Tool</h1>
  <p class=\"hint\">This UI runs pg_awr_report.sh on the server and returns the Markdown report.</p>
  <form method=\"post\">
    <div class=\"grid\">
      <label for=\"pghost\">PGHOST</label><input id=\"pghost\" name=\"pghost\" value=\"localhost\" />
      <label for=\"pgport\">PGPORT</label><input id=\"pgport\" name=\"pgport\" value=\"5432\" />
      <label for=\"pguser\">PGUSER</label><input id=\"pguser\" name=\"pguser\" />
      <label for=\"pgpassword\">PGPASSWORD</label><input id=\"pgpassword\" name=\"pgpassword\" type=\"password\" />
      <label for=\"pgdatabase\">PGDATABASE</label><input id=\"pgdatabase\" name=\"pgdatabase\" />
      <label for=\"interval\">Snapshot (seconds)</label><input id=\"interval\" name=\"interval\" value=\"60\" />
    </div>
    <button type=\"submit\">Run Snapshot</button>
  </form>
</body>
</html>
"""

REPORT_TEMPLATE = """<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\" />
  <title>PG AWR Snapshot Result</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 24px; }
    pre { background: #f5f5f5; padding: 12px; overflow: auto; }
    a { color: #0366d6; }
  </style>
</head>
<body>
  <h1>Snapshot Result</h1>
  <p><a href=\"/\">Run another snapshot</a></p>
  <pre>{report}</pre>
</body>
</html>
"""

ERROR_TEMPLATE = """<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\" />
  <title>PG AWR Snapshot Error</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 24px; }
    pre { background: #fff4f4; padding: 12px; border: 1px solid #f0b4b4; }
  </style>
</head>
<body>
  <h1>Snapshot Error</h1>
  <p><a href=\"/\">Back</a></p>
  <pre>{error}</pre>
</body>
</html>
"""


class ReportHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_error(404, "Not Found")
            return
        body = HTML_PAGE.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(content_length).decode("utf-8")
        form = parse_qs(data)

        env = os.environ.copy()
        env.update(
            {
                "PGHOST": form.get("pghost", [""])[0],
                "PGPORT": form.get("pgport", [""])[0],
                "PGUSER": form.get("pguser", [""])[0],
                "PGPASSWORD": form.get("pgpassword", [""])[0],
                "PGDATABASE": form.get("pgdatabase", [""])[0],
            }
        )

        interval = form.get("interval", ["60"])[0].strip() or "60"
        script_path = os.path.join(os.path.dirname(__file__), "pg_awr_report.sh")

        try:
            result = subprocess.run(
                [script_path, "-i", interval],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            report = html.escape(result.stdout)
            body = REPORT_TEMPLATE.format(report=report).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except subprocess.CalledProcessError as exc:
            error_msg = exc.stderr or exc.stdout or "Unknown error"
            body = ERROR_TEMPLATE.format(error=html.escape(error_msg)).encode("utf-8")
            self.send_response(500)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)


def main():
    port = int(os.environ.get("PORT", "8000"))
    server = HTTPServer(("0.0.0.0", port), ReportHandler)
    print(f"Listening on http://0.0.0.0:{port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
