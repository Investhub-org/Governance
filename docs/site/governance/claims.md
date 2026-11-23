# Claims

A dividend in this kit is a merkle epoch on `GvDividend`. The issuer's timelock opens it, after a vote. Anyone can fund it. Anyone can submit a claim. The tokens are paid to the account in the leaf, not to the caller. InvestHub does not custody the tokens and does not need to be online for a claim to succeed.

The contracts are unaudited. This is not investment advice. Build the tree from share balances, not from delegated votes. For a wrapper, expand the wrapper's underlying balance into the wrapper holders so the same unit is not paid twice.

## Open and fund

`startDistribution` is timelock-only, so it is an executed proposal. The arguments are the ERC-20, the merkle root, the sum of every leaf, a unix deadline, and a metadata URI of at most 1,024 bytes (for example a content id of the tree). The contract does not read that URI.

Claims stay closed until `funded` equals `totalAllocation`. Anyone can call `fund`. The contract pulls the epoch token from the caller and reverts if the token takes a fee, because the amount received must equal the amount requested. Funding after the deadline reverts.

## Claim

`claim(epoch, index, account, amount, proof)` pays one leaf. The leaf is the double hash used by OpenZeppelin's `StandardMerkleTree`:

```text
keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))
```

Indexes are unique and run from `0` to `n - 1` in the tree the issuer published. A claim does not loop over holders. Gas stays in the same band from the first leaf to the last. A 5,000-leaf proof is about 13 hashes.

The call reverts if the epoch is unknown, already swept, past the deadline, not fully funded, already claimed at that index, or if the proof does not match. The deadline second itself is still claimable.

The repository script `script/build_merkle.py` builds the tree. The proof for an account is public once the issuer publishes the tree. The holder, or anyone else, submits it. The transfer goes to `account`.

## After the deadline

A second proposal calls `sweep(epoch, to)`. Only the timelock can sweep, and only once, and only when the timestamp is strictly after the deadline. The amount is `funded - claimed`.

Tokens that someone transferred in without calling `fund` are not part of that amount. The timelock can recover them with `recoverSurplus(token, to)`, which sends `balance - reserved` and cannot take a funded epoch's remaining tokens.

## What you can read without an account

- `dividend.distribution(epoch)`: token, root, allocation, funded, claimed, deadline, metadata URI.
- `dividend.isClaimed(epoch, index)`.
- `DistributionStarted`, `DistributionFunded`, and `Claimed` logs.

No InvestHub API is required. A product client may prepare the unsigned calldata. The signature is still the holder's, and the dividend contract does not check who submitted the proof.
