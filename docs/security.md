# Security

**These contracts are unaudited.** They compose audited OpenZeppelin Contracts v5.6.1 blocks with factory, dividend, wrapper, directory, meeting, rules, information, share-terms, acquisition, and recovery code that has not had an independent review. Commission an external audit before an issuer relies on them for a real meeting, a real transfer restriction, or a real payment. A test suite, including a Base fork and a 5,000-holder claim simulation, is not a review. The numbers in `GvCompanyRules` are placeholders, not legal advice. See [legal-wrapper.md](legal-wrapper.md).

This is software. It is not investment advice, not an offer of securities, and not a statement that any person holds a financial-services or ECSP licence. The MIT text in the repository root is a copyright licence for the source code.

No contract in this repository was deployed to a live network as part of publishing it. The forge scripts refuse to run without a key you supply, and they still do nothing on a live network unless you pass `--broadcast` yourself.

## What to review first

- `GvDividend` custody: funding, the bitmap, the merkle proof, the sweep, and `recoverSurplus`. A bug here can lock or mis-pay the ERC-20.
- `GvKitFactory` role wiring: the governor must be the only proposer and executor, and the factory must not keep `DEFAULT_ADMIN_ROLE`.
- CREATE2 salts and the initcode helpers. `predict` and `deploy` must stay on the same bytes.
- The wrapper's `recover`. It is the timelock, and it must not be usable to seize tokens that holders deposited.
- Timestamp-clock integration with `getPastVotes`. Proposer votes are read at `clock() - 1`.
- `GvShare.moduleTransfer`. It skips the transfer policy. It must revert unless the caller is a module the timelock bound and that module reports the exact transfer as armed.
- `GvAcquisition.claimDrag`, `pushDrag`, `redirectUnclaimed`, and `GvRecovery.executeRecovery`. They are the only intended callers of that force path. Drag shares move only to the stored buyer. Redirected currency goes only to the rules' recipient. There should be no function that chooses an arbitrary share recipient.
- `GvShareTerms` whitelist and lock-up. The owner can block a transfer. The owner cannot seize a balance. Confirm ownership is the timelock before a live company relies on it.
- Placeholder parameters. An audit should treat a shipped default as unreviewed software, not as a statutory figure.

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
- An EGM convened by a director, and an EGM convened by a shareholder at the threshold and by holders combining support. The invitation event carries a hash and a CID, and the meeting cannot open during the notice.
- `articlesOutcome` passes an ordinary majority and fails a qualified majority on the same votes. Execution of that qualified vote reverts while `bindingMode` is Articles or Both. Governor mode lets it execute. The governor runtime is 17,915 bytes.
- A publication and an information request become overdue, then stop being overdue once a hash is stored.
- A recipient must be whitelisted and must have accepted the current SHA version, including by a relayed EIP-712 signature or a Merkle proof that then stores the acceptance. A lock-up blocks the holder until it expires. A configured treasury transfer and a mint skip pre-emption and emit `PrimaryIssuance`. A peer transfer does not. Pre-emption caps are pro rata. A stake at the tag threshold cannot use pre-emption.
- A drag at the placeholder quorum counts the buyer's snapshotted holding. A later balance increase does not raise that count. A later loss drops it. Recovery cannot create that loss while the drag is unsettled: `executeRecovery` reverts for a transfer onto the buyer and for a transfer off the buyer, including a court-order recovery. After the drag is cancelled, or the buyer holds every share, the same recovery can execute. After a drag executes, a holder pulls the same price, a batch push is capped at 32, and unclaimed consideration redirects only after the window and only to the configured recipient. Below quorum, the buyer is refunded and acceptors reclaim. A tag sale waits out its window and pays the same price pro rata. Recovery is not frozen during a tag.
- Convening support past 64 holders uses a votes snapshot. A transfer after the snapshot cannot be counted twice. `conveneByShareholders` uses `getPastVotes` at the previous second. A balance moved in the current second, including a flash loan, cannot convene.
- Recovery cannot execute before the delay. The holder can cancel a board resolution and cannot cancel a court-order path. A stranger cannot call `moduleTransfer`. The timelock is the only address that can set the policy.

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
| Allowlist | None until the timelock sets a transfer policy. `GvShareTerms` then enforces a whitelist, SHA acceptance, lock-ups, and pre-emption. A CMTAT rule engine, if any, stays on the issuer's underlying token. |
| Articles quorum | `GvGovernor` still has one quorum and the OpenZeppelin counting shape. `articlesOutcome` returns `GvCompanyRules.canonicalOutcome`. `bindingMode` selects Articles, the governor's counting shape at the class basis points, or both. `_executeOperations` calls `assertExecutable` before the timelock. Articles and Both revert when `passed` is false. Governor mode does not. `state()` is not rewritten. |
| Placeholders | `PLACEHOLDER_*` values are software defaults. They are not a reading of the PGR or the TVTG. |
| Drag and tag | `GvAcquisition` has no owner. The buyer's holding at posting counts toward the quorum, capped by the live balance. After execution each holder pulls the price, or a bounded push settles a small batch. Unclaimed currency redirects only to the rules' recipient, after the window. Shares move only to the buyer who escrowed. Tag is an explicit sale, not every transfer. |
| Recovery | One delayed transfer, one hash, events. A board-resolution recovery can be cancelled by the holder. A court-order recovery cannot. The timelock can cancel either. The hash is not verified against a document. Execution reverts while a drag is unsettled. |
| Force path | `moduleTransfer` cannot mint or burn. It calls the module's `mayForceTransfer` for that exact from, to, and amount. |
| Factory shape | Five deployer contracts, then the factory, because one contract that embedded every creation code would exceed the EIP-3860 initcode limit. |
| Governor code size | `GvGovernor` deployed runtime is 17,915 bytes. The margin under the 24,576-byte limit is 6,661 bytes. The articles formula lives on `GvAssembly`, which the governor calls. Recheck `forge inspect GvGovernor deployedBytecode` before adding more code to the governor. |
| Timelock change | `updateTimelock` remains OpenZeppelin's `onlyGovernance` function. The share minter and the dividend's timelock are immutable. They do not follow a governor timelock change. A change of timelock needs a new dividend and a new share if those must match. |
| Quorum | Numerator is a percent. The factory rejects 0 and anything above 100. OpenZeppelin's own setter allows 0; the factory does not. |
| Metadata | `metadataURI` on the factory and the dividend is capped at 1,024 bytes. The directory does not cap it. |
| Source of the replaced contracts | This kit replaces the idea of a custom ballot and a custom dividend with these OpenZeppelin blocks. The earlier test contracts were not available to copy from, so this is not a line-by-line port. |

## Out of scope

Identity, KYC, the Aktienbuch, corporate-law formality, tax, TVTG registration, and whether a particular token is a security. A successful on-chain proposal is a state change in these contracts. It does not, by itself, complete an off-chain legal step. The open questions for a Liechtenstein lawyer are listed in [legal-wrapper.md](legal-wrapper.md).

## Reporting

Report a vulnerability privately to the maintainers of this repository. Do not open a public issue that includes a working exploit against a deployment an issuer is using.
