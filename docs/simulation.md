# Lifecycle simulation

One synthetic company, from the issuer's own deployment to a completed drag-along. The run is local. `script/SimulateLifecycle.s.sol` reverts if Foundry is broadcasting, and it reverts if a script is resumed. Nothing in this flow is a public-network deployment.

The holders are not people. An address is the last 20 bytes of `keccak256("gv-sim-investor-v1" || index)` or `keccak256("gv-sim-role-v1" || role)`. There is no secp256k1 key for any of them. Profiles in `sim/` set `kyc` to false and `persona` to `synthetic`. The two documents under `sim/fixtures/` are placeholder text. Their hashes are what the chain stores.

This is the same software as the rest of the repository: unaudited, and not investment advice. See [README](../README.md) and [docs/legal-wrapper.md](legal-wrapper.md). Every default in `GvCompanyRules` is a placeholder.

## How to run

From the repository root, after `git submodule update --init --recursive`:

```bash
python3 sim/generate.py --holders 32 --check sim/fixtures/book-32.json
forge test
```

That is the CI path. `test_lifecycle_ci` walks 32 holders. `test_lifecycle_five_thousand` skips unless `SIM_HOLDERS` is at least 5000. `testFork_lifecycle_on_base` skips unless `BASE_RPC_URL` is set. The 5,000-holder dividend test that was already in the suite still runs.

```bash
SIM_HOLDERS=5000 forge test --match-test test_lifecycle_five_thousand -vv
python3 sim/generate.py --holders 5000 --out sim/out
```

`sim/out/` is gitignored. It contains `summary.json`, `investors.json`, `investors.csv`, and `dividend.json` (one proof per holder). The Python root and the Solidity log are the same value. For 5,000 holders that root is `0x098768e46dacb10756e71a1765b986e2a851fd4c8e3cd0f306d6e9e8d0d019a9`. The 32-holder fixture root is `0xe7ecab5622d6c72d88c6ef3849922e7c874036c5398b4b25cdee64e5b18bba07`.

The script is the same runner. It defaults to 5,000 holders. Do not pass `--broadcast`.

```bash
SIM_HOLDERS=32 forge script script/SimulateLifecycle.s.sol -vv
anvil --gas-limit 8000000000
SIM_HOLDERS=32 forge script script/SimulateLifecycle.s.sol --rpc-url http://127.0.0.1:8545 -vv
```

Anvil's default block gas limit is 30,000,000. The 32-holder script is one call of about 72,000,000 gas, and the 5,000-holder call is about 1,982,000,000, so the node has to be started with a higher limit. The in-memory `forge script` and `forge test` paths use the `gas_limit` in `foundry.toml` and do not need Anvil.

A Base fork reads the canonical USDC contract at `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (symbol and decimals, chain id 8453) and then runs the lifecycle with the mock token. The fork test uses 16 holders.

```bash
BASE_RPC_URL=https://mainnet.base.org forge test --match-test testFork_lifecycle_on_base -vv
SIM_FORK=true BASE_RPC_URL=https://mainnet.base.org SIM_HOLDERS=16 forge script script/SimulateLifecycle.s.sol -vv
```

`sim/generate.py` has no third-party dependencies. Keccak lives in `sim/keccak256.py` (domain byte `0x01`, the Ethereum function, not `hashlib.sha3_256`).

## What the run does

InvestHub is an address in the book. It is never whitelisted, never a director, never a share module, and it holds none of the timelock roles. The factory keeps no admin role. The governor is the timelock's proposer, executor, and canceller. The timelock is its own default admin. The executor is the governor, not `address(0)`.

Governor settings in the simulation are compressed so the vote can finish locally: voting delay 1 second, voting period 3,600 seconds, proposal threshold 1, quorum numerator 4 (4 percent), timelock delay 1 second. Assembly notice, the pre-emption window, the tag window, the information response window, the recovery delay, and the unclaimed-drag window stay on the placeholder durations and are crossed with `vm.warp`. `bindingMode` is set to `Articles`.

The consideration token is `MockERC20("Simulation USD", "USDC", 6)`. It is minted inside the test. It is not Circle USDC.

1. **Deploy.** The issuer deploys the five CREATE2 deployers and `GvKitFactory`, then an ownerless `GvDirectory`. `predict` matches `deploy`. The kit is the share (`Simulated Holdings`, `SIM`, 0 decimals, supply 1,000,000), the governor, the timelock, and the dividend. The issuer then deploys `GvCompanyRules`, `GvAssembly`, `GvInformation`, `GvShareTerms`, `GvAcquisition`, and `GvRecovery`, and points the terms at the acquisition contract. Salt is `keccak256("gv-sim-lifecycle-v1")`.
2. **Issue.** The issuer publishes the SHA hash, appoints the human director, and appoints the timelock as a director so a later executed proposal can fulfill a publication. The issuer's wallet is set as `issuerTreasury`. Onboarding is 5,006 accounts: the 5,000 investors, the issuer, the director, the pre-buyer, the tag buyer, the drag buyer, and the recovered holder. InvestHub is not in that list. Whitelist writes go through `setWhitelistBatch` in batches of 64. SHA acceptance is a Merkle root of `keccak256(bytes.concat(keccak256(abi.encode(account, shaVersion, shaHash))))`, published by the issuer, then `acceptShaWithProofBatch` in the same batches. Each account's `acceptedVersion` is stored, and `ShaAccepted` is emitted per account. The synthetic addresses have no keys, so this run uses the Merkle path. The EIP-712 relay is covered by `test_batch_whitelist_merkle_acceptance_and_eip712_relay`. The issuer delegates, and an executed proposal calls `setTransferPolicy` while the issuer still holds the book. That proposal is not bound to a meeting, so the articles gate checks it as a qualified resolution. The issuer's For vote is the whole supply, which passes the placeholder qualified quorum and majority. The issuer then transfers the book. Those transfers are treasury transfers: they skip pre-emption, they still require the whitelist and the current SHA, and each one emits `PrimaryIssuance`. A peer transfer from investor 3 reverts `PreEmptionRequired`. Investors 0 and 1 delegate to themselves, and the clock advances one second.
3. **Merkle tree.** Leaves are `keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))`, pairs are sorted, and an odd node is promoted. The amount is the share balance at issuance times `1_000_000` (one mock token per share). The tree is built before any secondary sale. Claims use that snapshot.
4. **Handover.** The issuer registers the directory and transfers ownership of the rules, the terms, and the assembly to the timelock.
5. **AGM.** The director schedules the annual-report publication and convenes a board AGM with three ordinary items: adopt the share terms, approve the annual report, approve the dividend. Investor 0 votes each proposal. The terms proposal calls `setTransferPolicy`, then `setShareModule` for the acquisition and for recovery. The report proposal calls `fulfillPublication`. The dividend proposal calls `startDistribution` with a 180-day claim deadline. The director closes the meeting. The terms proposal sets the same policy again, then arms the acquisition and recovery modules. The peer-transfer check already ran at distribution.
6. **Dividend.** The issuer approves and funds the epoch in full. Claims are submitted for indexes `0`, `1`, `n/2`, and `n-1`. Each claim pays the leaf account.
7. **EGM.** Investor 0 files a convening request and supports it. Support is that account's ERC-20 Votes weight at the second before the request, not a live balance and not a list capped at 64. `conveneByShareholders` uses the same kind of checkpoint: `getPastVotes` and `getPastTotalSupply` at the previous second. A balance borrowed in the current second cannot convene. This run uses the request path. Investor 0 already delegated and holds 320,000 votes, above the 10 percent placeholder, so one supporter is enough. A separate test convenes with 70 supporters. The only item is qualified: appoint an observer as a director. Investors 0 and 1 both vote. Together they have 500,000 votes, which is the 50 percent qualified-quorum placeholder on a supply of 1,000,000. The convener closes the meeting. `articlesOutcome.passed` is true under `BindingMode.Articles`. The governor proposal is `Executed`. On this vote both formulas pass. The unit test `test_articles_outcome_uses_the_resolution_class` is where a qualified majority fails the articles formula and passes the governor-shaped formula.
8. **Information.** The last holder files a request for a share-register extract. The response deadline is the filing time plus the 30-day placeholder. The clock moves to one second past that deadline, anyone notifies the overdue request, and the director answers. The request is marked late.
9. **Recovery.** A director proposes a board-resolution recovery of investor 6's whole balance to the recovered holder, with the hash of placeholder minutes. The clock moves to the 30-day placeholder. `executeRecovery` runs. Investor 6 holds nothing. The recovered holder holds that balance, is whitelisted, and has accepted the SHA. The order hash is not checked against a file.
10. **Pre-emption.** Investor 2 (120,000 shares) offers 10,000 at the book price. That stake is under the 30 percent tag threshold, so `startPreEmption` accepts it. Investor 1 exercises 1,000. Their cap is `10,000 * 180,000 / 880,000 = 2,045`, and 1,000 sits inside it. After the 14-day window the pre-buyer settles the remaining 9,000.
11. **Tag-along.** Investor 0 offers exactly 300,000 shares, which is the 30 percent tag threshold. `maxJoin` is `680,000 * 300,000 / 320,000 = 637,500`. The tag buyer escrows the price of the stake plus that cap. Investor 1 joins 1,000. After the window the sale settles and the joiner claims. The tag buyer then holds 301,000 shares.
12. **Drag-along.** The tag buyer is the buyer. They already hold 301,000, which is more than 25 percent, so the other 699,000 shares cannot reach a 75 percent quorum on their own. `postDrag` records `buyerHeldAtPost`. The buyer cannot tender. Investors 0 through 4 and the pre-buyer tender 499,000. Counted support is `499,000 + 301,000 = 800,000`, against a required 750,000. `executeDrag` finalises the offer and freezes transfers. The test contract calls `claimDrag` for seven accounts (investors 0 through 4, the pre-buyer, and the recovered holder). `pushDrag` settles the next 32 holders, which is the batch cap. Investor 7's peer transfer reverts `TransferWindowOpen`. Investor 3 withdraws. The clock then moves past the 365-day unclaimed window, and `redirectUnclaimed` credits the last holder's consideration to the reserve address. The other holders are not pushed. They still hold shares, those shares cannot move, and their consideration stays in escrow until someone claims it. Surplus is not refunded, because the buyer does not yet hold the supply.

The closing assertions: supply is unchanged, the acquisition contract and the terms contract and the issuer and the InvestHub address and the unused drag-buyer role hold no shares, the offer is executed, transfers are still frozen, and `paidOut` is less than the escrow. Investor 0's acquisition proceeds equal the original 320,000 shares times the price (tag stake plus the drag of the remainder). Investor 1's acquisition proceeds are 181,000 times the price (the 1,000 bought in the pre-emption, then sold, plus the original 180,000). Investor 2 has 10,000 times the price on the terms contract and 110,000 times the price on the acquisition contract. Investor 3 is outside the dividend sample, so after the withdrawal their wallet is exactly 100,000 times the price and their escrowed proceeds are zero. Investor 6's shares were recovered, so their drag proceeds are on the recovered holder. Investor 7 still holds their book balance and has no drag proceeds. The tag buyer's recorded proceeds are 636,500 times the price: the unused tag escrow credited back, and nothing for the 301,000 shares they already held, because a buyer is not paid for their own shares. The reserve's proceeds equal the last holder's book balance times the price. A conservation check sums the mock balances of the claimed wallets, the dividend contract, the terms contract, and the acquisition contract.

The placeholder recovery delay is 30 days, with a 7-day floor. The run executes one board-resolution recovery before the pre-emption.

## Gas

Figures are `vm.lastFrameGas().gasTotalUsed`: execution gas of that call, before refunds, including nested calls. Cheatcode calls are not included. A later call sees warm accounts. The 21,000 intrinsic transaction cost is not included. The same method is what the 5,000-holder dividend test in the README uses for its claim lines. Those README lines are a different address set (`address(uint160(0xA000 + i))`) measured in a dividend-only test. The numbers below are the lifecycle.

Foundry 1.9.0, solc 0.8.28, optimizer 200, EVM prague. `SIM_HOLDERS=5000`, one `simulate` call. `vm.unixTime` reported 8,318 ms from the start of `simulate` to the final log. The test process reported 8.32 s of CPU. The Foundry test-call gas was 1,980,971,983. `gasleft()` across `simulate`, which also counts the SHA Merkle build, the dividend Merkle copy, the mock mints, and the closing assertions, was 1,981,515,490. `foundry.toml` keeps `gas_limit` at 8,000,000,000. The run before the pull-claim path reported test-call gas 2,818,661,383 and `vm.unixTime` 39,643 ms.

Metered total: **894,634,196**. The pull-claim path metered **893,478,059**. The original per-holder conversion path metered **1,686,792,901**. The large drop is still the drag phase. The execution gate added about 1.16 million gas on top of the pull-claim path.

| Phase | Before | After |
| --- | --- | --- |
| Deploy | 38,275,952 | 40,140,350 |
| Issue | 780,753,584 | 839,014,674 |
| AGM | 2,476,712 | 2,456,846 |
| Dividend | 634,893 | 634,893 |
| EGM | 879,837 | 1,288,272 |
| Information | 281,190 | 281,257 |
| Recovery | not run | 412,275 |
| Pre-emption | 992,749 | 992,871 |
| Tag-along | 1,311,102 | 1,311,102 |
| Drag-along | 861,186,882 | 6,945,519 |
| Total | 1,686,792,901 | 893,478,059 |

The execution-gate run, measured the same way. "Pull-claim" is the column above. The delta is this change: the articles check on every execution, the past-vote convening path (this run still uses the request), and the drag-freeze read inside `blocksPeerTransfers`.

| Phase | Pull-claim | Execution gate | Delta |
| --- | --- | --- | --- |
| Deploy | 40,140,350 | 40,904,859 | +764,509 |
| Issue | 839,014,674 | 839,214,124 | +199,450 |
| AGM | 2,456,846 | 2,595,564 | +138,718 |
| Dividend | 634,893 | 634,893 | 0 |
| EGM | 1,288,272 | 1,332,816 | +44,544 |
| Information | 281,257 | 281,257 | 0 |
| Recovery | 412,275 | 420,540 | +8,265 |
| Pre-emption | 992,871 | 992,906 | +35 |
| Tag-along | 1,311,102 | 1,311,102 | 0 |
| Drag-along | 6,945,519 | 6,946,135 | +616 |
| Total | 893,478,059 | 894,634,196 | +1,156,137 |

Deploy is now infrastructure 16,497,823, kit `deploy` 8,744,802, and the terms stack 15,662,234. The kit figure includes the governor. Its deployed runtime is 17,915 bytes, 6,661 bytes under the 24,576-byte limit. Each executed proposal pays the gate: policy `execute` is 139,268 (was 114,720), the AGM terms `execute` is 185,194 (was 160,526), and the EGM `execute` is 148,247 (was 126,057). Distribution rose by about 35 gas a transfer because the policy now calls the shared drag-freeze helper. That is the rest of the issue-phase delta.

The pull-claim deploy, kept so the first table still has a breakdown, was infrastructure 16,317,755, kit `deploy` 8,568,565, and the terms stack 15,254,030. The terms stack had grown by the EIP-712 acceptance, the batches, and the pull claim. The governor bytecode in that run had not moved.

The calls that used to grow per holder, and what they cost now. Onboarding is 5,006 accounts (5,000 investors plus six roles). The previous whitelist and `acceptSha` totals are the 5,000 investor calls only. Distribution is 5,000 transfers. The previous drag line is 5,002 `convert` calls.

| Call | Before, total | After, total | After, first batch or call | After, last | After, average |
| --- | --- | --- | --- | --- | --- |
| Whitelist | 239,645,092 | 123,900,813 (79 batches) | 1,583,825 | 365,499 | 24,750 |
| SHA acceptance | 248,080,000 | 182,828,652 (79 batches) | 2,356,976 | 483,556 | 36,521 |
| Share `transfer` of the book | 292,131,220 | 531,258,480 | 128,520 | 106,248 | 106,251 |
| Drag settlement | 859,062,629 | 6,945,519 for the whole phase | one claim 184,744 | push of 32: 3,580,100 | does not walk the book |

A treasury transfer is an external call into the terms contract plus a `PrimaryIssuance` log. That is why the per-transfer average moved from 58,426 to 106,251. The policy was the point of the change. The previous figure is an unregulated ERC-20 transfer, taken before `setTransferPolicy`.

The drag phase at 5,000 holders is 6,945,519. At 32 holders it is 5,738,645. The difference is a push of 32 holders against a push of 21. Seven claims, one execution, and one redirect are the same size at both counts. The phase no longer walks the cap table.

Governance, the dividend, and the EGM do not grow with the holder count. The AGM subtotal is 2,456,846 at 32 holders and at 5,000. The EGM subtotal is 1,288,272 at both, up from 879,837 because the request path is a file, a support, and a convene.

| Call | Gas |
| --- | --- |
| Publish SHA, appoint both directors, set the treasury | 269,904 |
| Publish the SHA acceptance root | 52,360 |
| Adopt the transfer policy: `propose` / `vote` / `queue` / `execute` | 75,701 / 83,037 / 144,525 / 114,720 |
| Delegate the issuer, then the two founders | 95,498 + 190,984 |
| Directory register and ownership handover | 247,034 |
| Convene the AGM | 353,650 |
| AGM terms `propose` / `bind` / `vote` / `queue` / `execute` | 87,668 / 64,756 / 83,037 / 163,741 / 160,526 |
| AGM report `execute` | 156,969 |
| AGM dividend `execute` (`startDistribution`) | 237,168 |
| Approve and `fund` the epoch | 46,342 + 122,825 |
| `claim` index 0 / 1 / 2,500 / 4,999 | 134,671 / 100,481 / 117,535 / 113,039 |
| File the convening request / support it / convene | 263,227 / 83,682 / 320,562 |
| EGM `execute` (`setDirector`) | 126,057 |
| File the information request | 147,494 |
| Answer it, late | 105,507 |
| Propose recovery / execute it | 226,218 / 186,057 |
| `startPreEmption` / `exercisePreEmption` / `settle` | 329,554 / 308,704 / 215,577 |
| `openTagSale` / `joinTag` / `settleTag` / `claimTag` | 494,899 / 236,308 / 265,215 / 175,598 |
| `postDrag` | 279,682 |
| Seven `acceptDrag` calls | 1,173,688 |
| `executeDrag` | 63,935 |
| Seven `claimDrag` calls, first call | 1,267,025, first 184,744 |
| `pushDrag` of 32 holders | 3,580,100 |
| `redirectUnclaimed` | 184,270 |

The 32-holder CI run metered 60,785,335 gas and reported 17 ms. The pull-claim 32-holder total was 59,803,078. The original 32-holder total was 58,704,789. The latest run adds the articles gate on each execution. It still does not convert the whole book.

The dividend root for this book is `0x098768e46dacb10756e71a1765b986e2a851fd4c8e3cd0f306d6e9e8d0d019a9`. It is unchanged. The allocation is unchanged.

At 5,000 holders the smallest tail allotment is 4 shares. The head is fixed: 320,000, 180,000, 120,000, 100,000, 80,000. The other 200,000 shares follow `1_000_000 / (rank + 1)`, and the remainder is applied to the largest tail holder. Eight holders is the minimum the book accepts. Python and `InvestorBook.allocate` use the same integer division.

## Off-chain book

`sim/generate.py` writes the same addresses, the same share amounts, the same commitment (`shares * price`), and the same dividend leaves.

```bash
python3 sim/generate.py --holders 32 --fixture sim/fixtures/book-32.json
python3 sim/generate.py --holders 32 --check sim/fixtures/book-32.json
python3 sim/generate.py --holders 5000 --out sim/out
```

`test_book_matches_offchain_fixture` reads `sim/fixtures/book-32.json`, checks every investor, rebuilds the tree with `MerkleBuilder`, and checks the four sample proofs (indexes 0, 1, 16, 31). CI runs the Python `--check` before `forge test`.

## Mapping to InvestHub tools

The contracts do not call InvestHub. The tools below are the product surface a reader would look at for the same lifecycle. ECSP, where it is offered, is through a licensed partner and is in review. The tools are not this kit, and a simulation draft is not a live offering.

| Step in this run | Tool | What that tool does |
| --- | --- | --- |
| Incorporate, deploy the kit | none | No tool deploys `GvKitFactory`. Deployment is the issuer's transaction, as in [docs/gv-without-investhub.md](gv-without-investhub.md). |
| Launch a deal | `create_deal_draft` | Stores an off-chain draft. It does not publish a live offering and it does not deploy these contracts. |
| Commit | `express_interest`, then `commit_to_opportunity` | Interest is a note on the profile. The commit is a soft-commit. Calldata for `approve` plus `commit(bytes32,uint256)` is returned only when `COMMIT_CONTRACT_BASE` is set. The server does not sign. |
| Issue the book | `prepare_invest` | Builds an INV subscription against the live sale (cap, supply, whitelist, price). That sale is not this share token. |
| Delegate and vote | `gv_siwe_nonce`, `gv_siwe_verify`, `gv_prepare_delegate`, `gv_prepare_vote` | SIWE, then an unsigned `delegate` or `castVote` (`Ja`, `Nein`, `Enthaltung`). The server does not sign and does not vote. `gv_list_proposals` and `gv_get_proposal` return public metadata until a holder session exists. `prepare_vote` refuses a simulated agenda vote and points at that SIWE path. `list_meetings` and `get_meeting` are public metadata. `gv_prepare_wrap` prepares `approve` plus `depositFor` for a wrapper such as wINV-votes. A native `GvShare` has no wrapper step. |
| Start or fund a `GvDividend` epoch | none | No tool calls `startDistribution` or `fund`. |
| Claim | `get_claimable`, `prepare_claim` | Read `getClaimable` and build an unsigned `withdraw` on the dividend pack the deals page documents, or on the pack selected with `gv_id` `gv-e2e-iht-test`. That calldata is not `GvDividend.claim(epoch, index, account, amount, proof)`. |

## What this run now exercises

The previous run worked around eight gaps. This run uses the contract paths.

1. The tag buyer is the drag buyer and holds 301,000 shares. `buyerHeldAtPost` counts, capped by the live balance. Counted support is 800,000 against a required 750,000. A buyer cannot tender, so those shares are not counted twice. Recovery cannot move shares while that drag is unsettled, so it cannot inflate or deflate the count.
2. The book is transferred after `setTransferPolicy`, from the configured `issuerTreasury`. Each transfer emits `PrimaryIssuance`. A peer transfer reverts `PreEmptionRequired`.
3. Whitelist and SHA acceptance are batches of 64. The SHA path in this run is a Merkle proof. `acceptedVersion` is stored per account. EIP-712 `acceptShaBySig` is the holder-signed alternative and is unit-tested with a real key. These synthetic addresses have no keys.
4. The EGM uses a convening request. Support is `getPastVotes` at the second before the request. There is no supporter cap. `test_convening_support_scales_past_sixty_four_holders` convenes with 70 accounts.
5. `articlesOutcome` returns `GvCompanyRules.canonicalOutcome`. `bindingMode` is `Articles`. Before the timelock runs, the governor calls `GvAssembly.assertExecutable`. Articles and Both revert when `passed` is false. Governor mode does not add that check. This run's votes pass. `test_execution_obeys_articles_unless_binding_mode_is_governor` is the vote that the governor would execute and the articles refuse, until the mode is switched to Governor.
6. Recovery is proposed and executed before the drag. Investor 6's balance moves to the recovered holder. The same call reverts once a drag is posted, in both directions, and runs again after the drag is cancelled or the buyer holds every share.

## What is still open

1. **The factory CREATE2-deploys four contracts.** Share, timelock, governor, and dividend. Rules, assembly, information, terms, acquisition, and recovery are separate issuer deployments. That split is the EIP-3860 initcode limit described in the README.
2. **There is no subscribe or commit contract in this kit.** The commitment column in the book is `shares * price`. It is not an on-chain escrow.
3. **`state()` can still read Succeeded or Queued while execution reverts.** The refusal is `assertExecutable` inside `_executeOperations`. Tally can show a proposal as ready. The timelock does not run when the mode is Articles or Both and `passed` is false. Governor mode skips that check. The governor still has one quorum numerator for every class. Aligning the numbers means setting that numerator beside `quorumBps / 100`.
4. **A holder can raise a proposal's class by binding it to a stricter agenda item.** Execution uses the strictest class. An unbound proposal is checked as qualified. A binding cannot lower the class. That blocks a weak classification. It also lets one holder make an ordinary proposal harder to execute.
5. **Recovery is not frozen during an open tag sale.** `dragUnsettled` covers a posted drag until the buyer holds every share. A tag sale sets `blocksPeerTransfers` on its own. A recovery can still move shares during that sale.
6. **A Merkle acceptance is the issuer's root.** The on-chain record is still `acceptedVersion` on the account. It is not a signature by the holder. The EIP-712 path is the holder's proof. This run sets the root before ownership moves to the timelock.
7. **Unclaimed drag consideration stays in the contract** until a claim or a redirect. Redirect pays the recipient configured on the company rules, not the holder. The placeholder window is 365 days. The software floor is 180 days and the cap is 1,825 days. Those bounds are not a statute.
8. **Primary distribution is still one transfer per holder.** The policy call and the `PrimaryIssuance` log are why that phase is larger than the unregulated transfers in the first table. There is no batched ERC-20 distribution.
9. **The 5,000-holder drag does not settle the whole cap table.** Seven claims, one push of 32, and one redirect. The remaining holders keep frozen shares and unclaimed consideration. That is the pull model. `pushDrag` reverts above 32.
10. **Undelegated shares are absent** from governor weights, from convening-request support, and from `conveneByShareholders`. That path now reads `getPastVotes` at the previous second. A flash loan in the current second cannot convene. A holder who never delegates cannot convene on it either.
