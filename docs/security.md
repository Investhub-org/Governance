# Security

**These contracts are unaudited.** They compose audited OpenZeppelin Contracts v5.6.1 blocks with new factory, dividend, wrapper, and directory code that has not had an independent review. Commission an external audit before an issuer relies on them for a real meeting or a real payment. A test suite, including a Base fork and a 5,000-holder claim simulation, is not a review.

This is software. It is not investment advice, not an offer of securities, and not a statement that any person holds a financial-services or ECSP licence. The MIT text in the repository root is a copyright licence for the source code.

No contract in this repository was deployed to a live network as part of publishing it. The forge scripts refuse to run without a key you supply, and they still do nothing on a live network unless you pass `--broadcast` yourself.

## What to review first

- `GvDividend` custody: funding, the bitmap, the merkle proof, the sweep, and `recoverSurplus`. A bug here can lock or mis-pay the ERC-20.
- `GvKitFactory` role wiring: the governor must be the only proposer and executor, and the factory must not keep `DEFAULT_ADMIN_ROLE`.
- CREATE2 salts and the initcode helpers. `predict` and `deploy` must stay on the same bytes.
- The wrapper's `recover`. It is the timelock, and it must not be usable to seize tokens that holders deposited.
- Timestamp-clock integration with `getPastVotes`. Proposer votes are read at `clock() - 1`.

## Properties the tests cover

- The factory has no timelock role after `deploy`. The timelock keeps its own admin role. `address(0)` is not an executor.
- The same issuer cannot reuse a salt. Two issuers can.
- A native share mints later only through an executed proposal.
- For, Against, and Abstain, quorum (For + Abstain), and a snapshot that ignores a transfer made after it.
- A proposer can cancel only while the proposal is pending. OpenZeppelin's governor does not cancel a queued proposal from the public `cancel` function.
- Dividend access: only the timelock starts an epoch, claims wait until the epoch is fully funded, a bad proof fails, a claim pays the leaf, a second claim fails, and sweep of an empty remainder fails. After the deadline the timelock can sweep the unclaimed amount, and a stranger cannot.
- A plain ERC-20 can be wrapped. A votes token on a block-number clock is rejected.
- The directory is unused by the governor. Only the registering issuer or the stored timelock can edit the entry. There is no `owner()`.
- A stranger cannot call a deployer.
- 5,000 claims pay the full allocation and the claim gas does not grow with the index.
- On a Base fork, with `BASE_RPC_URL` set: propose, vote, queue, execute, fund canonical Base USDC, and claim. The fork test is skipped when the variable is unset.

## Open decisions

These are choices, not leftovers. An audit should treat them as intended unless the issuer decides otherwise.

| Topic | Decision |
| --- | --- |
| Upgrades | None. No proxy and no proxy admin. A new meeting is a new deployment. |
| OpenZeppelin | v5.6.1, the audited release. v5.7.0 was the `dev` tag and was not used. |
| Clock | Timestamp (ERC-6372), not block number. Voting delay and period are seconds. |
| Decimals | The issuer chooses 0 to 18. Tests use 0. |
| Supply | The issuer receives the initial native supply. Later minting is only the timelock. There is no burn function. |
| CMTAT v3 | Not ERC-5805. Use `GvVotesWrapper`, or an existing votes token that already reports `mode=timestamp`. |
| Timelock admin | The timelock itself. The deployer and the factory renounce. There is no guardian. |
| Executor | The governor contract. The open executor role is not granted. |
| Cancel | OpenZeppelin v5.6 lets the proposer cancel only while the proposal is `Pending`. The canceller role on the timelock does not, by itself, cancel a queued proposal through `governor.cancel`. |
| Claims | Anyone may submit a proof. The tokens go to the account in the leaf. Indexes are unique and must be `0..n-1` in the tree builder. |
| Funding | Claims stay closed until `funded == totalAllocation`. A fee-on-transfer token is rejected. |
| Sweep | Only the timelock, and only when `block.timestamp > deadline`. The deadline second itself is still claimable. |
| Surplus | `recoverSurplus` sends `balance - reserved` and cannot touch funded-but-unclaimed tokens. |
| Directory | Self-asserted. It does not prove the factory deployed the listed contracts. The kit works with an empty directory. |
| Leaf | `keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))`, sorted pairs, odd nodes promoted. Same double hash as OpenZeppelin's `StandardMerkleTree`. |
| Allowlist | None. The contracts do not check identity. A CMTAT rule engine, if any, stays on the issuer's token. |
| Factory shape | Five deployer contracts, then the factory, because one contract that embedded every creation code would exceed the EIP-3860 initcode limit. |
| Governor code size | `GvGovernor` is the OpenZeppelin wizard set and nothing else. The deployer runtime margin over the 24,576-byte limit is a few thousand bytes. Do not add code to the governor without rechecking `forge build --sizes`. |
| Timelock change | `updateTimelock` remains OpenZeppelin's `onlyGovernance` function. The share minter and the dividend's timelock are immutable. They do not follow a governor timelock change. A change of timelock needs a new dividend and a new share if those must match. |
| Quorum | Numerator is a percent. The factory rejects 0 and anything above 100. OpenZeppelin's own setter allows 0; the factory does not. |
| Metadata | `metadataURI` on the factory and the dividend is capped at 1,024 bytes. The directory does not cap it. |
| Source of the replaced contracts | This kit replaces the idea of a custom ballot and a custom dividend with these OpenZeppelin blocks. The earlier test contracts were not available to copy from, so this is not a line-by-line port. |

## Out of scope

Identity, KYC, shareholder registers, corporate-law formality, tax, and whether a particular token is a security. A successful on-chain proposal is a state change in these contracts. It does not, by itself, complete an off-chain legal step.

## Reporting

Report a vulnerability privately to the maintainers of this repository. Do not open a public issue that includes a working exploit against a deployment an issuer is using.
