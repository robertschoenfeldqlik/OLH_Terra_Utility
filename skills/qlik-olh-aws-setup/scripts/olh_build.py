"""
Local CLI for the Qlik Open Lakehouse AWS builder.

    python olh_build.py config.json --mode plan|build|verify [--out outputs.json]

Uses your local boto3 credentials. All the logic lives in olh_core.py, which is
also the file you hand to the AWS MCP connector's run_script; this wrapper only
adds what that sandbox forbids (boto3, argparse, getattr).
"""
import argparse
import asyncio
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from olh_core import run  # noqa: E402


def boto_call():
    import boto3
    from botocore import xform_name
    clients = {}

    async def call(*, service_name, operation_name, region_name=None, params=None):
        key = (service_name, region_name)
        if key not in clients:
            clients[key] = boto3.client(service_name, region_name=region_name)
        return getattr(clients[key], xform_name(operation_name))(**(params or {}))
    return call


def main():
    ap = argparse.ArgumentParser(description="Build, plan or verify the Qlik Open Lakehouse AWS prerequisites")
    ap.add_argument("config")
    ap.add_argument("--mode", choices=["plan", "build", "verify"], default="plan")
    ap.add_argument("--out", help="write the result JSON here (build outputs feed olh_emit.py)")
    a = ap.parse_args()
    with open(a.config, encoding="utf-8") as f:
        cfg = json.load(f)
    result = asyncio.run(run(cfg, boto_call(), a.mode))
    text = json.dumps(result, indent=2, default=str)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
