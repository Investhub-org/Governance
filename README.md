# Governance kit

Issuer-owned contracts for a general meeting and a dividend. An issuer deploys the kit, holds the shares, and runs proposals through an OpenZeppelin Governor and Timelock. InvestHub is not a party to these contracts. It has no admin role, no pause, no upgrade key, and no claim on the tokens.

This repository is software. The MIT licence in [LICENSE](LICENSE) is a copyright licence for that software. It is not a financial-services licence, not an ECSP licence, and not permission to offer securities. Nothing here is investment advice. The contracts are **unaudited**. Read [docs/security.md](docs/security.md) before using them.

How to deploy and vote without the InvestHub UI: [docs/gv-without-investhub.md](docs/gv-without-investhub.md).

How the articles and a shareholder agreement can point at these contracts, which numbers are placeholders rather than law, and why Aktionariat's contracts were not copied: [docs/legal-wrapper.md](docs/legal-wrapper.md). Draft clauses for a lawyer to rewrite: [docs/templates/articles-draft.md](docs/templates/articles-draft.md) and [docs/templates/sha-draft.md](docs/templates/sha-draft.md).

An off-chain planner for notice, record, vote, dividend, pre-emption, and drag/tag dates: [docs/lifecycle-deadlines.md](docs/lifecycle-deadlines.md). It does not send, sign, or take payment. The day counts are defaults to verify with Liechtenstein counsel. They are not legal advice.

## Independence

| Piece | Who controls it |
| --- | --- |
| `GvShare` or the issuer's existing token | The issuer. Later minting of a native share is only the kit timelock, after a vote. |
| `GvVotesWrapper` | Holders, by depositing and withdrawing. The timelock can recover tokens that were not deposited through the wrapper. The wrapper does not take a CMTAT admin, minter, pauser, or rule-engine role. |
| `GvGovernor` | Token holders who have delegated. Settings change only through a proposal. |
| `TimelockController` | Itself. The governor is proposer, executor, and canceller. The factory renounces the temporary admin it used to grant those roles. |
| `GvDividend` | The timelock starts an epoch and, after the deadline, sweeps what was not claimed. Anyone can fund or submit a claim. Tokens are paid to the leaf account. |
| `GvKitFactory` | Nobody. It stores the deployment and emits `IssuerKitDeployed`. It keeps no role. |
| `GvDirectory` | Optional. The issuer, or the timelock they stored, edits their own pointer. The kit does not read it. |
| `GvCompanyRules` | The issuer. Transfer ownership to the timelock after counsel replaces the placeholders. |
| `GvAssembly` | The issuer appoints directors. Shareholders convene when they meet the stored threshold. |
| `GvInformation` | Directors publish hashes. Shareholders file requests. |
| `GvShareTerms` | The issuer, for the whitelist, the SHA hash, and lock-ups. The share token ignores it until the timelock sets the policy. |
| `GvAcquisition` | No owner. A buyer posts an offer. A drag can force a transfer only after the timelock has set this contract as a share module, and only for the stored buyer. |
| `GvRecovery` | A director proposes one delayed transfer with a document hash. The timelock can cancel it. |

A meeting is still the governor. `GvAssembly` records whether it is an AGM or an EGM, the notice, the agenda, and the invitation hash. Anyone can read `propose`, `state`, `quorum`, the assembly, and the timelock from chain data. A directory entry is not required and is not proof that the factory deployed those addresses. The factory event is the deployment record. The new modules are not inside the factory. The issuer deploys them and the timelock wires the share token. They keep working if the directory is empty.

## What is deployed

Solidity 0.8.28, Foundry, OpenZeppelin Contracts v5.6.1 (the audited `v5.6.1` release, not the `v5.7.0` dev tag).

1. **Share.** `GvShare` is ERC-20 + `ERC20Permit` + `ERC20Votes` with an ERC-6372 timestamp clock (`CLOCK_MODE` is `mode=timestamp`). Decimals are chosen by the issuer, from 0 to 18.
2. **Existing token.** CMTAT v3 is an ERC-20. It does not implement ERC-5805, so a Governor cannot use it as the votes token directly. Deposit it into `GvVotesWrapper`, or pass an existing votes token whose clock is already `mode=timestamp`.
3. **Governor.** OpenZeppelin `Governor`, `GovernorSettings`, `GovernorCountingSimple` (For / Against / Abstain), `GovernorVotes`, `GovernorVotesQuorumFraction`, and `GovernorTimelockControl`. This is the OpenZeppelin Contracts Wizard shape, which is what Tally indexes. Quorum counts For and Abstain. For must be strictly greater than Against. Delay, period, quorum numerator (percent), threshold, and timelock delay are constructor arguments.
4. **Timelock.** OpenZeppelin `TimelockController`. The executor role is the governor contract, not the open role `address(0)`. There is no separate guardian.
5. **Dividend.** One merkle epoch per distribution, in the Uniswap merkle-distributor pattern. The epoch is funded with an ERC-20 (USDC in the Base example). Claims are closed until the full allocation has been funded. A claim is one proof and one transfer, so a few thousand holders do not require a loop. Unclaimed tokens return only to a call from the timelock after the deadline.
6. **Factory.** CREATE2 deployment of the four kit contracts. `IssuerKitDeployed(issuer, share, governor, timelock, dividend, metadataURI)`.
7. **Directory.** Optional and ownerless.

The factory's constructor does not embed the other contracts. EIP-3860 limits initcode to 49,152 bytes, so the deployers are separate transactions. See the deploy guide.

## Votes are not the balance

A holder calls `delegate` on the votes token, usually to themselves. The governor reads proposer votes at `clock() - 1`, so a delegation made in the current second is not visible until the next second. Transfers move votes only for accounts that have already delegated. The snapshot for a proposal is `clock() + votingDelay` at the time of `propose`.

Build a dividend tree from share balances, not from delegated votes. For a wrapper, expand the wrapper's underlying balance into the wrapper holders so the same unit is not paid twice.

## Build and test

```bash
forge install
forge test
forge test --gas-report
node --experimental-strip-types --test lifecycle/deadlines/test/deadlines.test.ts
```

The deadline test needs Node 22. It does not compile the contracts and it does not touch a network.

`test/GvFork.t.sol` forks Base and runs propose, vote, queue, execute, fund, and claim. It runs only when `BASE_RPC_URL` is set to a Base RPC. Unset, the test is skipped. It does not broadcast. The fork funds the test contract with canonical Base USDC (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, a token contract) when the client can write that balance, and otherwise uses a test ERC-20 on the fork.

```bash
BASE_RPC_URL=https://mainnet.base.org forge test --match-contract GvForkTest -vv
```

Holder addresses in the tests come from `makeAddr` or from `address(uint160(0xA000 + i))`. No member wallet is in the source.

## Gas, measured without a fork

`forge test --gas-report` on Foundry 1.9.0, solc 0.8.28, optimizer 200 runs, EVM version prague. The 5,000-holder test logs the call that matters, because each claim is an external call:

| Call | Gas |
| --- | --- |
| `startDistribution` for 5,000 holders | 182,283 |
| `fund` of the full allocation | 123,425 |
| `claim` index 0 | 118,702 |
| `claim` index 256 | 101,572 |
| `claim` index 4,999 | 99,671 |

Starting an epoch does not grow with the holder count. Claim gas stays in a band of under 20,000 from the first leaf to the last. A 5,000-leaf proof is about 13 hashes.

Function averages from the same report, in gas: `propose` 72,228, `castVote` 83,170, `queue` 146,023, `execute` 187,522, `GvShare.delegate` 95,533, `GvDividend.fund` 122,817. `GvKitFactory.deploy` is dominated by creating the governor and the share. Those averages include the whole suite, not a single warm call.

Runtime bytecode from `forge build --sizes` (EIP-170 limit 24,576, EIP-3860 initcode limit 49,152):

| Contract | Runtime | Initcode |
| --- | --- | --- |
| `GvKitFactory` | 11,438 | 12,304 |
| `GvGovernor` | 17,169 | 19,847 |
| `GvGovernorDeployer` | 21,013 | 21,190 |
| `GvShare` | 8,522 | 11,760 |
| `GvDividend` | 5,570 | 5,798 |
| `GvDirectory` | 2,192 | 2,220 |
| `GvCompanyRules` | 6,404 | 8,897 |
| `GvAssembly` | 13,593 | 14,378 |
| `GvInformation` | 5,987 | 6,236 |
| `GvShareTerms` | 10,625 | 11,238 |
| `GvAcquisition` | 14,579 | 15,281 |
| `GvRecovery` | 4,823 | 5,291 |
| `GvShareDeployer` | 12,893 | 13,070 |

`GvShare` was 7,450 bytes before the optional transfer-policy hook. With the hook unset, a transfer does not call a policy. The gas averages above are from that earlier measurement. `GvGovernor` is unchanged. The new modules sit under the 24,576-byte runtime limit. Every default in `GvCompanyRules` is a placeholder a Liechtenstein lawyer has to replace. See [docs/legal-wrapper.md](docs/legal-wrapper.md).

## Layout

```
src/GvShare.sol
src/GvVotesWrapper.sol
src/GvGovernor.sol
src/GvDividend.sol
src/GvKitFactory.sol
src/GvDirectory.sol
src/GvCompanyRules.sol
src/GvAssembly.sol
src/GvInformation.sol
src/GvShareTerms.sol
src/GvAcquisition.sol
src/GvRecovery.sol
src/deployers/GvDeployers.sol
script/DeployInfrastructure.s.sol
script/DeployIssuerKit.s.sol
script/DeployIssuerTerms.s.sol
script/build_merkle.py
test/
docs/gv-without-investhub.md
docs/legal-wrapper.md
docs/lifecycle-deadlines.md
docs/security.md
docs/templates/
lifecycle/deadlines/
```

OpenZeppelin and forge-std are git submodules under `lib/`, pinned in `.gitmodules` and `foundry.lock`.
