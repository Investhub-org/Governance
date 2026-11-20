"""Keccak-256, the Ethereum hash, not NIST SHA3-256.

The padding domain byte is 0x01. hashlib.sha3_256 uses 0x06 and will not match `cast keccak`.
"""

from __future__ import annotations

# Indexed by [x][y], with lane index x + 5*y. Matches KeccakRhoOffsets.
_ROTATION = (
    (0, 36, 3, 41, 18),
    (1, 44, 10, 45, 2),
    (62, 6, 43, 15, 61),
    (28, 55, 25, 21, 56),
    (27, 20, 39, 8, 14),
)

_ROUND = (
    0x0000000000000001,
    0x0000000000008082,
    0x800000000000808A,
    0x8000000080008000,
    0x000000000000808B,
    0x0000000080000001,
    0x8000000080008081,
    0x8000000000008009,
    0x000000000000008A,
    0x0000000000000088,
    0x0000000080008009,
    0x000000008000000A,
    0x000000008000808B,
    0x800000000000008B,
    0x8000000000008089,
    0x8000000000008003,
    0x8000000000008002,
    0x8000000000000080,
    0x000000000000800A,
    0x800000008000000A,
    0x8000000080008081,
    0x8000000000008080,
    0x0000000080000001,
    0x8000000080008008,
)

_MASK = (1 << 64) - 1


def _rotl(value: int, shift: int) -> int:
    shift %= 64
    if shift == 0:
        return value
    return ((value << shift) | (value >> (64 - shift))) & _MASK


def _permute(state: list[int]) -> None:
    for round_constant in _ROUND:
        column = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
        diagonal = [column[(x - 1) % 5] ^ _rotl(column[(x + 1) % 5], 1) for x in range(5)]
        for index in range(25):
            state[index] ^= diagonal[index % 5]

        rotated = [0] * 25
        for x in range(5):
            for y in range(5):
                rotated[y + 5 * ((2 * x + 3 * y) % 5)] = _rotl(state[x + 5 * y], _ROTATION[x][y])

        for y in range(5):
            base = 5 * y
            for x in range(5):
                state[base + x] = rotated[base + x] ^ ((~rotated[base + ((x + 1) % 5)] & _MASK) & rotated[base + ((x + 2) % 5)])

        state[0] ^= round_constant


def keccak256(data: bytes) -> bytes:
    """Return the 32-byte Keccak-256 digest of `data`."""
    rate = 136
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate != 0:
        padded.append(0)
    padded[-1] |= 0x80

    state = [0] * 25
    for offset in range(0, len(padded), rate):
        block = padded[offset : offset + rate]
        for lane in range(rate // 8):
            state[lane] ^= int.from_bytes(block[lane * 8 : (lane + 1) * 8], "little")
        _permute(state)

    out = bytearray()
    while len(out) < 32:
        for lane in range(rate // 8):
            out += state[lane].to_bytes(8, "little")
            if len(out) >= 32:
                break
        if len(out) < 32:
            _permute(state)
    return bytes(out[:32])


def self_check() -> None:
    empty = bytes.fromhex("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    abc = bytes.fromhex("4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
    if keccak256(b"") != empty or keccak256(b"abc") != abc:
        raise SystemExit("keccak256 does not match the Ethereum test vectors")
