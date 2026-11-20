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

Anvil's default block gas limit is 30,000,000. The 32-holder script is one call of about 69,000,000 gas, and the 5,000-holder call is about 2,820,000,000, so the node has to be started with a higher limit. The in-memory `forge script` and `forge test` paths use the `gas_limit` in `foundry.toml` and do not need Anvil.

A Base fork reads the canonical USDC contract at `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (symbol and decimals, chain id 8453) and then runs the lifecycle with the mock token. The fork test uses 16 holders.

```bash
BASE_RPC_URL=https://mainnet.base.org forge test --match-test testFork_lifecycle_on_base -vv
SIM_FORK=true BASE_RPC_URL=https://mainnet.base.org SIM_HOLDERS=16 forge script script/SimulateLifecycle.s.sol -vv
```

`sim/generate.py` has no third-party dependencies. Keccak lives in `sim/keccak256.py` (domain byte `0x01`, the Ethereum function, not `hashlib.sha3_256`).

## What the run does

InvestHub is an address in the book. It is never whitelisted, never a director, never a share module, and it holds none of the timelock roles. The factory keeps no admin role. The governor is the timelock's proposer, executor, and canceller. The timelock is its own default admin. The executor is the governor, not `address(0)`.

Governor settings in the simulation are compressed so the vote can finish locally: voting delay 1 second, voting period 3,600 seconds, proposal threshold 1, quorum numerator 4 (4 percent), timelock delay 1 second. Assembly notice, the pre-emption window, the tag window, and the information response window stay on the placeholder durations and are crossed with `vm.warp`.

The consideration token is `MockERC20("Simulation USD", "USDC", 6)`. It is minted inside the test. It is not Circle USDC.

1. **Deploy.** The issuer deploys the five CREATE2 deployers and `GvKitFactory`, then an ownerless `GvDirectory`. `predict` matches `deploy`. The kit is the share (`Simulated Holdings`, `SIM`, 0 decimals, supply 1,000,000), the governor, the timelock, and the dividend. The issuer then deploys `GvCompanyRules`, `GvAssembly`, `GvInformation`, `GvShareTerms`, `GvAcquisition`, and `GvRecovery`, and points the terms at the acquisition contract. Salt is `keccak256("gv-sim-lifecycle-v1")`.
2. **Issue.** The issuer publishes the SHA hash, appoints the human director, and appoints the timelock as a director so a later executed proposal can fulfill a publication. The issuer, the director, the pre-buyer, the tag buyer, the drag buyer, and every investor are whitelisted and each calls `acceptSha`. The issuer then transfers the book. The transfer policy is still unset, so those transfers are plain ERC-20 transfers. Investors 0 and 1 delegate to themselves, and the clock advances one second.
3. **Merkle tree.** Leaves are `keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))`, pairs are sorted, and an odd node is promoted. The amount is the share balance at issuance times `1_000_000` (one mock token per share). The tree is built before any secondary sale. Claims use that snapshot.
4. **Handover.** The issuer registers the directory and transfers ownership of the rules, the terms, and the assembly to the timelock.
5. **AGM.** The director schedules the annual-report publication and convenes a board AGM with three ordinary items: adopt the share terms, approve the annual report, approve the dividend. Investor 0 votes each proposal. The terms proposal calls `setTransferPolicy`, then `setShareModule` for the acquisition and for recovery. The report proposal calls `fulfillPublication`. The dividend proposal calls `startDistribution` with a 180-day claim deadline. The director closes the meeting. A peer transfer after this point reverts `PreEmptionRequired`.
6. **Dividend.** The issuer approves and funds the epoch in full. Claims are submitted for indexes `0`, `1`, `n/2`, and `n-1`. Each claim pays the leaf account.
7. **EGM.** Investor 0 holds 32 percent and convenes the EGM directly. The placeholder meeting-call threshold is 10 percent. The only item is qualified: appoint an observer as a director. Investors 0 and 1 both vote. Together they have 500,000 votes, which is the 50 percent qualified-quorum placeholder on a supply of 1,000,000. The convener closes the meeting.
8. **Information.** The last holder files a request for a share-register extract. The response deadline is the filing time plus the 30-day placeholder. The clock moves to one second past that deadline, anyone notifies the overdue request, and the director answers. The request is marked late.
9. **Pre-emption.** Investor 2 (120,000 shares) offers 10,000 at the book price. That stake is under the 30 percent tag threshold, so `startPreEmption` accepts it. Investor 1 exercises 1,000. Their cap is `10,000 * 180,000 / 880,000 = 2,045`, and 1,000 sits inside it. After the 14-day window the pre-buyer settles the remaining 9,000.
10. **Tag-along.** Investor 0 offers exactly 300,000 shares, which is the 30 percent tag threshold. `maxJoin` is `680,000 * 300,000 / 320,000 = 637,500`. The tag buyer escrows the price of the stake plus that cap. Investor 1 joins 1,000. After the window the sale settles and the joiner claims. The tag buyer and the drag buyer are different addresses: a buyer cannot accept their own drag, and the quorum below is measured against the full supply.
11. **Drag-along.** The drag buyer starts with zero shares and escrows `price * totalSupply`. Seven holders tender 800,000 shares (the tag buyer, investors 0 through 4, and the pre-buyer), which clears the 75 percent placeholder. `executeDrag` runs, then `convert` for every remaining balance: 5,002 conversions at 5,000 holders (every investor, plus the pre-buyer and the tag buyer). Surplus is refunded. Investor 3 withdraws.

The closing assertions: the drag buyer holds the whole supply, the supply is unchanged, the acquisition contract and the terms contract and the issuer and the InvestHub address hold no shares, `paidOut` equals the escrow, and every investor's share balance is zero. Proceeds match the sales. Investor 0's acquisition proceeds equal the original 320,000 shares times the price (tag stake plus the drag of the remainder). Investor 1's acquisition proceeds are 181,000 times the price (the 1,000 bought in the pre-emption, then sold, plus the original 180,000). Investor 2 has 10,000 times the price on the terms contract and 110,000 times the price on the acquisition contract. Investor 3 is outside the claim sample, so after the withdrawal their wallet is exactly 100,000 times the price and their escrowed proceeds are zero. The tag buyer's recorded proceeds are 937,500 times the price: the unused tag escrow credited back, plus the drag price of the 301,000 shares they held. A conservation check sums the mock balances of the claimed wallets, the dividend contract, the terms contract, and the acquisition contract.

Recovery is deployed and armed as a share module. The run does not execute a recovery. The placeholder delay is 30 days, with a 7-day floor.

## Gas

Figures are `vm.lastFrameGas().gasTotalUsed`: execution gas of that call, before refunds, including nested calls. Cheatcode calls are not included. A later call sees warm accounts. The 21,000 intrinsic transaction cost is not included. The same method is what the 5,000-holder dividend test in the README uses for its claim lines. Those README lines are a different address set (`address(uint160(0xA000 + i))`) measured in a dividend-only test. The numbers below are the lifecycle.

Foundry 1.9.0, solc 0.8.28, optimizer 200, EVM prague. `SIM_HOLDERS=5000`, one `simulate` call. `vm.unixTime` reported 39,643 ms from the start of `simulate` to the final log. The test process reported 42.08 s of CPU. The Foundry test-call gas, which also counts the Merkle copy, the mock mints, and the closing assertions, was 2,818,661,383. `foundry.toml` sets `gas_limit` to 8,000,000,000 because that single call does not fit in 2,000,000,000.

Metered total: **1,686,792,901**.

| Phase | Gas |
| --- | --- |
| Deploy | 38,275,952 |
| Issue | 780,753,584 |
| AGM | 2,476,712 |
| Dividend | 634,893 |
| EGM | 879,837 |
| Information | 281,190 |
| Pre-emption | 992,749 |
| Tag-along | 1,311,102 |
| Drag-along | 861,186,882 |

Deploy breaks down as infrastructure 16,317,323, kit `deploy` 8,568,357, and the terms stack 13,390,272.

The issue and drag phases are the ones that grow with the holder count.

| Call, 5,000 investors | First | Last | Average | Total |
| --- | --- | --- | --- | --- |
| `setWhitelist` | 47,930 | 47,930 | 47,929 | 239,645,092 |
| `acceptSha` | 49,616 | 49,616 | 49,616 | 248,080,000 |
| Share `transfer` of the book | 58,439 | 58,427 | 58,426 | 292,131,220 |
| Drag `convert` (5,002 calls) | 199,001 | 164,801 | 171,743 | 859,062,629 |

`convert` includes the pre-buyer and the tag buyer, so the count is 5,002. The first call pays the cold write. Later calls stay near 165,000.

Governance and the dividend do not grow with the holder count. The AGM subtotal is the same 2,476,712 at 32 holders and at 5,000.

| Call | Gas |
| --- | --- |
| Publish SHA and appoint both directors | 218,558 |
| Delegate the two founders | 190,984 |
| Directory register and ownership handover | 247,044 |
| Convene the AGM | 353,672 |
| AGM terms `propose` / `bind` / `vote` / `queue` / `execute` | 87,668 / 64,734 / 83,037 / 163,741 / 180,426 |
| AGM report `execute` | 156,969 |
| AGM dividend `execute` (`startDistribution`) | 237,168 |
| Approve and `fund` the epoch | 46,342 + 122,825 |
| `claim` index 0 / 1 / 2,500 / 4,999 | 134,671 / 100,481 / 117,535 / 113,039 |
| Convene the EGM | 259,036 |
| EGM `execute` (`setDirector`) | 126,079 |
| File the information request | 147,427 |
| Answer it, late | 105,507 |
| `startPreEmption` / `exercisePreEmption` / `settle` | 329,500 / 308,659 / 215,554 |
| `openTagSale` / `joinTag` / `settleTag` / `claimTag` | 494,970 / 236,263 / 265,213 / 175,574 |
| `postDrag` | 255,073 |
| Seven `acceptDrag` calls | 1,317,566 |
| `executeDrag` | 53,743 |
| `refundDragSurplus` | 54,763 |

The 32-holder CI run metered 58,704,789 gas and reported 15 ms. Same phases, with whitelist, acceptance, distribution, and `convert` scaled down to 32 investors (34 conversions, including the two buyers).

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

## Gaps this run ran into

These are observations from driving the contracts on `main` (`1f247378`, the articles and shareholder-terms change). The simulation works around them. The contracts are unchanged.

1. **`buyerHeldAtPost` is stored and never read.** `postDrag` writes `token.balanceOf(msg.sender)` onto the offer. `_required` is `ceil(supplyAtPost * quorumBps / 10_000)` of accepted shares. `acceptDrag` reverts `BuyerCannotAccept` for the buyer, so shares the buyer already holds cannot be tendered and do not count. A buyer who already holds more than 25 percent cannot reach a 75 percent quorum measured against the full supply. The drag buyer in this run starts at zero. The tag buyer is a different address for the same reason.
2. **A treasury transfer after the policy is on reverts `PreEmptionRequired`.** `authorizeTransfer` lets a mint (`from == address(0)`) through after the recipient checks, unless a sale is blocking transfers. Any other transfer, including one from the issuer's own balance, hits pre-emption while `preEmptionEnabled` is true, which is the default. This run distributes the book before `setTransferPolicy`. A later issuance is a timelock `mint`, not a transfer out of a treasury wallet.
3. **Whitelist and `acceptSha` are one account per call.** Five thousand holders is five thousand of each. That is most of the 780,753,584 gas in the issue phase. There is no batch entry point.
4. **The factory CREATE2-deploys four contracts.** Share, timelock, governor, and dividend. Rules, assembly, information, terms, acquisition, and recovery are separate issuer deployments. That split is the EIP-3860 initcode limit described in the README, and `DeployIssuerTerms` already follows it.
5. **There is no subscribe or commit contract in this kit.** The commitment column in the book is `shares * price`. It is not an on-chain escrow.
6. **Governor quorum and `articlesOutcome` answer different questions.** The governor's quorum numerator counts For and Abstain against past supply. `articlesOutcome` compares participation (For + Against + Abstain) with the class quorum in basis points, and compares For with For + Against for the class majority. Abstentions are outside that majority denominator. A proposal can be `Executed` and still fail `articlesOutcome`. This run asserts both.
7. **A convening request stops at 64 supporters.** `GvAssembly.MAX_SUPPORTERS` is 64. Sixty-four equal holders out of 5,000 are about 1.28 percent of supply, under the 10 percent meeting-call placeholder, so that path cannot convene a dispersed book. This run does not use the request path. Investor 0 convenes the EGM because their balance clears the threshold on its own.
8. **Recovery is armed and not exercised.** `GvRecovery` is a share module by the end of the AGM. The 30-day delay is outside the path this simulation was asked to walk.
