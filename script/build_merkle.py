#!/usr/bin/env python3
"""Build a GvDividend merkle tree.

Leaf = keccak256(keccak256(abi.encode(index, account, amount)))
Pairs are sorted. An odd node is promoted, not duplicated.
The inner and outer hashes match GvDividend.hashLeaf and OpenZeppelin MerkleProof.

Requires `cast` from Foundry on PATH. No third-party hash library.

Input JSON on stdin or as a file argument:
{
  "claims": [
    {"index": 0, "account": "0xabc...", "amount": "1000000"}
  ]
}

Indexes must be unique. Amounts are integer token units (USDC has 6 decimals).
Output JSON: root, total, and each claim with its proof (hex bytes32 list).
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys


def keccak(data: bytes) -> bytes:
    if shutil.which("cast") is None:
        sys.exit("cast is not on PATH. Install Foundry and retry.")
    hexdata = "0x" + data.hex()
    out = subprocess.check_output(["cast", "keccak", hexdata], text=True).strip()
    return bytes.fromhex(out.removeprefix("0x"))


def abi_word(value: int) -> bytes:
    if value < 0 or value >= 1 << 256:
        sys.exit(f"value does not fit in uint256: {value}")
    return value.to_bytes(32, "big")


def hash_leaf(index: int, account: str, amount: int) -> bytes:
    addr = account.lower().removeprefix("0x")
    if len(addr) != 40:
        sys.exit(f"account is not an address: {account}")
    encoded = abi_word(index) + abi_word(int(addr, 16)) + abi_word(amount)
    return keccak(keccak(encoded))


def hash_pair(a: bytes, b: bytes) -> bytes:
    left, right = (a, b) if a < b else (b, a)
    return keccak(left + right)


def build(leaves: list[bytes]) -> list[list[bytes]]:
    if not leaves:
        sys.exit("no claims")
    levels = [leaves]
    current = leaves
    while len(current) > 1:
        nxt: list[bytes] = []
        i = 0
        while i < len(current):
            if i + 1 == len(current):
                nxt.append(current[i])
            else:
                nxt.append(hash_pair(current[i], current[i + 1]))
            i += 2
        levels.append(nxt)
        current = nxt
    return levels


def proof(levels: list[list[bytes]], index: int) -> list[str]:
    out: list[str] = []
    idx = index
    for level in levels[:-1]:
        sibling = idx ^ 1
        if sibling < len(level):
            out.append("0x" + level[sibling].hex())
        idx //= 2
    return out


def load(path: str | None) -> dict:
    raw = sys.stdin.read() if path in (None, "-") else open(path, encoding="utf-8").read()
    data = json.loads(raw)
    claims = data["claims"]
    seen: set[int] = set()
    for claim in claims:
        index = int(claim["index"])
        if index in seen:
            sys.exit(f"duplicate index {index}")
        seen.add(index)
        claim["index"] = index
        claim["amount"] = int(claim["amount"])
        if claim["amount"] <= 0:
            sys.exit(f"amount must be positive at index {index}")
    claims.sort(key=lambda c: c["index"])
    return {"claims": claims}


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else "-"
    data = load(path)
    claims = data["claims"]
    # Leaves are stored at their index. Gaps are rejected so a missing holder cannot shift the tree.
    if [c["index"] for c in claims] != list(range(len(claims))):
        sys.exit("indexes must be 0..n-1 with no gaps")
    leaves = [hash_leaf(c["index"], c["account"], c["amount"]) for c in claims]
    levels = build(leaves)
    total = sum(c["amount"] for c in claims)
    result = {
        "root": "0x" + levels[-1][0].hex(),
        "total": str(total),
        "leafEncoding": "keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))",
        "claims": [
            {
                "index": c["index"],
                "account": c["account"],
                "amount": str(c["amount"]),
                "proof": proof(levels, c["index"]),
            }
            for c in claims
        ],
    }
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
