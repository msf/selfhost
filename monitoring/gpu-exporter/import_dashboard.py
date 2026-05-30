#!/usr/bin/env python3
"""Import r9700-gpu.json into Grafana via the HTTP API.

The provisioning dir is root-owned, so we push the git-tracked dashboard JSON
through the API instead. Resolves the VictoriaMetrics datasource uid at runtime
and rewrites every panel/target datasource to match.
"""
import json
import os
import sys
import urllib.request

BASE = os.environ.get("GRAFANA_URL", "http://localhost:3000")
USER = os.environ.get("GRAFANA_USER", "msf")
PW = os.environ["GRAFANA_PASSWORD"]
HERE = os.path.dirname(os.path.abspath(__file__))
DASH = os.path.join(HERE, "..", "grafana", "dashboards", "r9700-gpu.json")


def api(path, data=None):
    url = f"{BASE}{path}"
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method="POST" if data else "GET")
    req.add_header("Content-Type", "application/json")
    import base64
    tok = base64.b64encode(f"{USER}:{PW}".encode()).decode()
    req.add_header("Authorization", f"Basic {tok}")
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def resolve_uid():
    for d in api("/api/datasources"):
        if d["type"] == "prometheus" and "victoria" in d["name"].lower():
            return d["uid"]
    for d in api("/api/datasources"):
        if d["type"] == "prometheus":
            return d["uid"]
    raise SystemExit("no prometheus datasource found")


def rewrite_ds(obj, uid):
    if isinstance(obj, dict):
        if obj.get("datasource", {}) and isinstance(obj["datasource"], dict) \
                and obj["datasource"].get("type") == "prometheus":
            obj["datasource"]["uid"] = uid
        for v in obj.values():
            rewrite_ds(v, uid)
    elif isinstance(obj, list):
        for v in obj:
            rewrite_ds(v, uid)


def main():
    uid = resolve_uid()
    dash = json.load(open(DASH))
    rewrite_ds(dash, uid)
    dash.pop("id", None)
    res = api("/api/dashboards/db", {"dashboard": dash, "overwrite": True})
    print("datasource_uid:", uid)
    print("status:", res.get("status"))
    print("url:", BASE + res.get("url", ""))
    print("public:", "https://graf.mfilipe.eu" + res.get("url", ""))


if __name__ == "__main__":
    main()
