# Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
# Part of caml-harness, an OCaml re-implementation of Harness2 (Google LLC, Apache-2.0); see NOTICE.

"""A minimal A2A-over-stdio agent: the template for wrapping Jev (or any model) as an agent.

caml-harness writes one JSON-RPC 2.0 "message/send" request to stdin and reads one
response from stdout whose "result" is an A2A task. This example answers eval-judge
requests by passing any deliverable that starts with "Total: ".

Replace `answer()` with a call to Jev and keep the envelope as it is.

    CAML_HARNESS_JEV_CMD="python3 scripts/stdio_agent_example.py" \
      caml-harness demo --judge jev
"""

import json
import sys
import uuid


def answer(text: str) -> str:
    deliverable = text.split("DELIVERABLE:\n", 1)[-1].split("\n\nAnswer with", 1)[0]
    verdict = "pass" if deliverable.strip().startswith("Total: ") else "fail"
    return f"```verdict\n{verdict}\n```"


def main() -> int:
    request = json.load(sys.stdin)
    message = request["params"]["message"]
    text = "\n".join(p.get("text", "") for p in message.get("parts", []) if p.get("kind") == "text")
    parts = [{"kind": "text", "text": answer(text)}]
    reply = {
        "kind": "message",
        "messageId": str(uuid.uuid4()),
        "contextId": message.get("contextId", ""),
        "taskId": message.get("taskId", ""),
        "role": "agent",
        "parts": parts,
    }
    task = {
        "kind": "task",
        "id": message.get("taskId") or str(uuid.uuid4()),
        "contextId": message.get("contextId", ""),
        "status": {"state": "completed", "message": ""},
        "history": [message, reply],
        "artifacts": [{"artifactId": str(uuid.uuid4()), "name": "reply", "parts": parts}],
    }
    json.dump({"jsonrpc": "2.0", "id": request.get("id"), "result": task}, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
