#!/usr/bin/env python3
"""Synthetic investor book for the governance lifecycle simulation.

The addresses, share allocation, and dividend Merkle tree match
`script/lifecycle/InvestorBook.sol` and `GvDividend.hashLeaf`. Nothing here is a
person, a KYC record, or a wallet that has a key. Addresses are the last 20
bytes of a keccak, not secp256k1 accounts.

Examples, from the repository root:

    python3 sim/generate.py --holders 32 --fixture sim/fixtures/book-32.json
    python3 sim/generate.py --holders 32 --check sim/fixtures/book-32.json
    python3 sim/generate.py --holders 5000 --out sim/out
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from keccak256 import keccak256, self_check

ROOT = Path(__file__).resolve().parents[1]

# Keep these in lockstep with script/lifecycle/InvestorBook.sol.
SUPPLY = 1_000_000
HEAD_BPS = (3200, 1800, 1200, 1000, 800)
HEAD_COUNT = 5
MIN_HOLDERS = 8
MAX_HOLDERS = 5000
DIVIDEND_PER_SHARE = 1_000_000
PRICE = 1_000_000
SEGMENTS = ("SIM-A", "SIM-B", "SIM-C", "SIM-D")
ROLES = ("issuer", "director", "pre-buyer", "tag-buyer", "drag-buyer", "investhub", "observer")
ROLE_KEYS = {
    "issuer": "issuer",
    "director": "director",
    "pre-buyer": "preBuyer",
    "tag-buyer": "tagBuyer",
    "drag-buyer": "dragBuyer",
    "investhub": "investhub",
    "observer": "observer",
}
SAMPLE_INDEXES = (0, 1, 16, 31)


def weight(rank: int) -> int:
    return 1_000_000 // (rank + 1)


def allocate(holders: int) -> list[int]:
    if holders < MIN_HOLDERS or holders > MAX_HOLDERS:
        raise SystemExit(f"holder count {holders} is outside {MIN_HOLDERS}..{MAX_HOLDERS}")
    shares = [0] * holders
    head_sum = 0
    for index, bps in enumerate(HEAD_BPS):
        shares[index] = SUPPLY * bps // 10_000
        head_sum += shares[index]
    tail_supply = SUPPLY - head_sum
    tail_count = holders - HEAD_COUNT
    sum_weights = sum(weight(rank) for rank in range(tail_count))
    allocated = 0
    for rank in range(tail_count):
        part = tail_supply * weight(rank) // sum_weights
        if part == 0:
            part = 1
        shares[HEAD_COUNT + rank] = part
        allocated += part
    if allocated > tail_supply:
        over = allocated - tail_supply
        if shares[HEAD_COUNT] <= over:
            raise SystemExit("tail remainder does not fit the largest tail holder")
        shares[HEAD_COUNT] -= over
    elif allocated < tail_supply:
        shares[HEAD_COUNT] += tail_supply - allocated
    if sum(shares) != SUPPLY or min(shares) < 1:
        raise SystemExit("allocation does not sum to the supply")
    return shares


def investor_address(index: int) -> str:
    digest = keccak256(b"gv-sim-investor-v1" + index.to_bytes(32, "big"))
    return "0x" + digest[-20:].hex()


def role_address(name: str) -> str:
    digest = keccak256(b"gv-sim-role-v1" + name.encode())
    return "0x" + digest[-20:].hex()


def hash_leaf(index: int, account: str, amount: int) -> bytes:
    address_word = int(account, 16).to_bytes(32, "big")
    encoded = index.to_bytes(32, "big") + address_word + amount.to_bytes(32, "big")
    return keccak256(keccak256(encoded))


def hash_pair(left: bytes, right: bytes) -> bytes:
    ordered = (left, right) if left < right else (right, left)
    return keccak256(ordered[0] + ordered[1])


def build_levels(leaves: list[bytes]) -> list[list[bytes]]:
    levels = [leaves]
    current = leaves
    while len(current) > 1:
        nxt: list[bytes] = []
        index = 0
        while index < len(current):
            if index + 1 == len(current):
                nxt.append(current[index])
            else:
                nxt.append(hash_pair(current[index], current[index + 1]))
            index += 2
        levels.append(nxt)
        current = nxt
    return levels


def proof_for(levels: list[list[bytes]], index: int) -> list[str]:
    out: list[str] = []
    cursor = index
    for level in levels[:-1]:
        sibling = cursor ^ 1
        if sibling < len(level):
            out.append("0x" + level[sibling].hex())
        cursor //= 2
    return out


def document_hash(name: str) -> str:
    return "0x" + keccak256((ROOT / "sim" / "fixtures" / name).read_bytes()).hex()


def build_book(holders: int) -> dict:
    shares = allocate(holders)
    investors = []
    leaves = []
    for index, amount in enumerate(shares):
        account = investor_address(index)
        dividend = amount * DIVIDEND_PER_SHARE
        investors.append(
            {
                "index": index,
                "id": f"sim-{index:05d}",
                "label": f"sim-holder-{index:05d}",
                "address": account,
                "shares": amount,
                "commitment": amount * PRICE,
                "dividend": dividend,
                "kyc": False,
                "persona": "synthetic",
                "segment": SEGMENTS[index % len(SEGMENTS)],
            }
        )
        leaves.append(hash_leaf(index, account, dividend))
    levels = build_levels(leaves)
    sample = []
    for index in SAMPLE_INDEXES:
        if index < holders:
            sample.append({"index": index, "proof": proof_for(levels, index)})
    roles = {ROLE_KEYS[name]: role_address(name) for name in ROLES}
    return {
        "holders": holders,
        "supply": SUPPLY,
        "price": PRICE,
        "dividendPerShare": DIVIDEND_PER_SHARE,
        "root": "0x" + levels[-1][0].hex(),
        "dividendTotal": SUPPLY * DIVIDEND_PER_SHARE,
        "shaHash": document_hash("sha.txt"),
        "annualReportHash": document_hash("annual-report.txt"),
        "roles": roles,
        "investors": investors,
        "sampleProofs": sample,
        "leafEncoding": "keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))",
        "addressDerivation": "last 20 bytes of keccak256(gv-sim-investor-v1 || uint256 index)",
    }


def _expect(label: str, got, want) -> None:
    if got != want:
        raise SystemExit(f"{label} mismatch:\n got  {got}\n want {want}")


def check_fixture(path: Path, holders: int) -> None:
    book = build_book(holders)
    saved = json.loads(path.read_text(encoding="utf-8"))
    for key in ("holders", "supply", "price", "dividendPerShare", "root", "dividendTotal", "shaHash", "annualReportHash"):
        _expect(key, saved.get(key), book[key])
    _expect("roles", saved.get("roles"), book["roles"])
    saved_investors = saved.get("investors")
    if not isinstance(saved_investors, list) or len(saved_investors) != holders:
        raise SystemExit("fixture investor list has the wrong length")
    for index, (saved_row, fresh) in enumerate(zip(saved_investors, book["investors"])):
        _expect(f"investor {index} address", saved_row.get("address"), fresh["address"])
        _expect(f"investor {index} shares", saved_row.get("shares"), fresh["shares"])
        _expect(f"investor {index} dividend", saved_row.get("dividend"), fresh["dividend"])
        _expect(f"investor {index} commitment", saved_row.get("commitment"), fresh["commitment"])
    _expect("sampleProofs", saved.get("sampleProofs"), book["sampleProofs"])
    print(f"fixture matches {path} ({holders} holders, root {book['root']})", file=sys.stderr)


def write_fixture(path: Path, book: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(book, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {path}", file=sys.stderr)


def write_out(directory: Path, book: dict) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    summary = {key: value for key, value in book.items() if key != "investors"}
    summary["investors"] = [
        {
            "index": row["index"],
            "address": row["address"],
            "shares": row["shares"],
            "commitment": row["commitment"],
            "dividend": row["dividend"],
        }
        for row in book["investors"]
    ]
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    profiles = []
    claims = []
    # Rebuild proofs for every holder. The fixture only stores a sample.
    shares = [row["shares"] for row in book["investors"]]
    leaves = [
        hash_leaf(row["index"], row["address"], row["dividend"]) for row in book["investors"]
    ]
    levels = build_levels(leaves)
    for row in book["investors"]:
        profiles.append(
            {
                "index": row["index"],
                "id": row["id"],
                "label": row["label"],
                "address": row["address"],
                "shares": str(row["shares"]),
                "commitment": str(row["commitment"]),
                "dividend": str(row["dividend"]),
                "kyc": False,
                "persona": row["persona"],
                "segment": row["segment"],
            }
        )
        claims.append(
            {
                "index": row["index"],
                "account": row["address"],
                "amount": str(row["dividend"]),
                "proof": proof_for(levels, row["index"]),
            }
        )
    (directory / "investors.json").write_text(json.dumps(profiles, indent=2) + "\n", encoding="utf-8")
    dividend = {
        "root": book["root"],
        "total": str(book["dividendTotal"]),
        "leafEncoding": book["leafEncoding"],
        "claims": claims,
    }
    (directory / "dividend.json").write_text(json.dumps(dividend) + "\n", encoding="utf-8")
    with (directory / "investors.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=(
                "index",
                "id",
                "label",
                "address",
                "shares",
                "commitment_usdc",
                "dividend_usdc",
                "kyc",
                "persona",
                "segment",
            ),
        )
        writer.writeheader()
        for row in book["investors"]:
            writer.writerow(
                {
                    "index": row["index"],
                    "id": row["id"],
                    "label": row["label"],
                    "address": row["address"],
                    "shares": row["shares"],
                    "commitment_usdc": row["commitment"],
                    "dividend_usdc": row["dividend"],
                    "kyc": "false",
                    "persona": row["persona"],
                    "segment": row["segment"],
                }
            )
    del shares
    print(
        f"wrote {directory} ({book['holders']} holders, root {book['root']}, "
        f"min tail {min(row['shares'] for row in book['investors'][HEAD_COUNT:])})",
        file=sys.stderr,
    )


def main() -> None:
    self_check()
    parser = argparse.ArgumentParser(description="Build the synthetic investor book and dividend tree.")
    parser.add_argument("--holders", type=int, required=True)
    parser.add_argument("--fixture", type=Path, help="Write the compact JSON the Forge test reads.")
    parser.add_argument("--check", type=Path, help="Recompute the book and exit non-zero on any mismatch.")
    parser.add_argument("--out", type=Path, help="Write investors.json, investors.csv, dividend.json, and summary.json.")
    args = parser.parse_args()
    if args.check is not None:
        check_fixture(args.check, args.holders)
        return
    if args.fixture is None and args.out is None:
        raise SystemExit("pass --fixture, --check, or --out")
    book = build_book(args.holders)
    if args.fixture is not None:
        write_fixture(args.fixture, book)
    if args.out is not None:
        write_out(args.out, book)


if __name__ == "__main__":
    main()
