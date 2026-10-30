#!/usr/bin/env python3
"""Check the model inventory (governance/model-inventory/model_inventory.yaml).

1. Every model has the required fields, a valid risk rating and a review date
   that isn't in the past.
2. Optional: --deployed <file> takes a JSON list of what the platform actually
   serves, each item {"deployment_name", "provider_model", "deployment_type"}
   (made by the cloud-specific script in scripts/). It fails if anything in use
   isn't in the inventory ("shadow models"), or doesn't match it.

Usage:
  python3 scripts/check_model_inventory.py
  python3 scripts/check_model_inventory.py --deployed models-in-use.json
"""
import argparse
import datetime as dt
import json
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "governance" / "model-inventory" / "model_inventory.yaml"
REQUIRED = [
    "id", "name", "deployment_name", "provider_model", "deployment_type", "region",
    "business_owner", "technical_owner", "purpose", "risk_rating", "data_classification",
    "human_oversight", "controls", "validation", "monitoring", "next_review", "status",
]
RISK = {"Low", "Medium", "High"}


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--inventory", default=str(INVENTORY))
    p.add_argument("--deployed")
    args = p.parse_args()

    models = yaml.safe_load(open(args.inventory))["models"]
    problems: list[str] = []
    today = dt.date.today()
    for m in models:
        mid = m.get("id", "<no id>")
        problems += [f"{mid}: missing '{f}'" for f in REQUIRED if not m.get(f)]
        if m.get("risk_rating") not in RISK:
            problems.append(f"{mid}: risk_rating must be one of {sorted(RISK)}")
        if not (m.get("validation") or {}).get("last_validated"):
            problems.append(f"{mid}: validation.last_validated is missing")
        try:
            if dt.date.fromisoformat(str(m.get("next_review"))) < today:
                problems.append(f"{mid}: next_review {m['next_review']} is in the past")
        except ValueError:
            problems.append(f"{mid}: next_review must be YYYY-MM-DD")

    if args.deployed:
        by_name = {m["deployment_name"]: m for m in models}
        for d in json.load(open(args.deployed)):
            m = by_name.get(d["deployment_name"])
            if not m:
                problems.append(f"in use but NOT in the inventory: {d['deployment_name']} ({d['provider_model']})")
                continue
            for field in ("provider_model", "deployment_type"):
                if str(d.get(field)) != str(m.get(field)):
                    problems.append(f"{d['deployment_name']}: {field} in use is {d.get(field)}, inventory says {m.get(field)}")

    if problems:
        print("MODEL INVENTORY: FAIL")
        for pr in problems:
            print(" -", pr)
        return 1
    print(f"MODEL INVENTORY: OK ({len(models)} model(s){', matches what is in use' if args.deployed else ''})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
