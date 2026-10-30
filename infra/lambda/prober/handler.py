"""The in-VPC prober: a tiny Lambda that runs tests from INSIDE the private VPC.

Your laptop can't reach anything in the lab VPC (that's the point), so every
"prove it" test in the course sends a request to this function instead.
It plays the role the jump VM plays in the Azure course.

Actions (the "action" field of the event):
  probe   DNS check for Bedrock + one Converse call.
          {"action": "probe", "model_id": "...", "guardrail_id": "...", "guardrail_version": "1"}
  http    Any HTTP request from inside the VPC (to the gateway or the app).
          {"action": "http", "method": "POST", "url": "http://...", "headers": {...}, "body": {...}}
  eval    The week 8 release gate: golden questions against the app.
          {"action": "eval", "url": "http://...", "cases": [...]}
"""
import json
import os
import socket
import time
import urllib.error
import urllib.request

REGION = os.environ.get("AWS_REGION", "ca-central-1")


def _probe(event):
    import boto3  # bundled in the Lambda Python runtime

    host = f"bedrock-runtime.{REGION}.amazonaws.com"
    ips = sorted({ai[4][0] for ai in socket.getaddrinfo(host, 443)})
    private = all(ip.startswith("10.") for ip in ips)
    result = {"dns": {host: ips, "private": private}}

    kwargs = {
        "modelId": event["model_id"],
        "messages": [{"role": "user", "content": [{"text": event.get("prompt", "Say hello from a private VPC in one short sentence.")}]}],
        "inferenceConfig": {"maxTokens": 60},
    }
    if event.get("guardrail_id"):
        kwargs["guardrailConfig"] = {
            "guardrailIdentifier": event["guardrail_id"],
            "guardrailVersion": str(event.get("guardrail_version", "DRAFT")),
        }
    client = boto3.client("bedrock-runtime", region_name=REGION)
    try:
        resp = client.converse(**kwargs)
        result["converse"] = {
            "status": "OK",
            "stopReason": resp.get("stopReason"),
            "answer": resp["output"]["message"]["content"][0]["text"],
            "usage": resp.get("usage"),
        }
    except Exception as e:  # show the error class: AccessDenied vs network vs validation
        result["converse"] = {"status": "ERROR", "error": type(e).__name__, "message": str(e)[:400]}
    return result


def _http(method, url, headers=None, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            status = r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read().decode(), e.code
    except Exception as e:
        return {"status": 0, "error": f"{type(e).__name__}: {e}"}
    try:
        parsed = json.loads(raw)
    except ValueError:
        parsed = raw[:1000]
    return {"status": status, "body": parsed}


def _eval(event):
    results = []
    for c in event["cases"]:
        r = _http("POST", event["url"].rstrip("/") + "/ask", body={"question": c["question"]}, timeout=90)
        answer = r.get("body", {}).get("answer", "") if isinstance(r.get("body"), dict) else str(r)
        low = answer.lower()
        missing = [s for s in c.get("must_contain", []) if s.lower() not in low]
        forbidden = [s for s in c.get("must_not_contain", []) if s.lower() in low]
        ok = r.get("status") == 200 and not missing and not forbidden
        results.append({"id": c["id"], "pass": ok, "missing": missing, "forbidden": forbidden, "answer": answer[:160]})
        time.sleep(1)
    passed = sum(x["pass"] for x in results)
    return {"gate": "GO" if passed == len(results) else "NO-GO", "passed": passed, "total": len(results), "results": results}


def handler(event, context):
    action = event.get("action", "probe")
    if action == "probe":
        return _probe(event)
    if action == "http":
        return _http(event.get("method", "GET"), event["url"], event.get("headers"), event.get("body"))
    if action == "eval":
        return _eval(event)
    return {"error": f"unknown action {action}"}
