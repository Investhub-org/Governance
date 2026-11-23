# Run a meeting without InvestHub

The issuer uses a wallet they control. InvestHub does not sign, does not hold a role, and does not need to be online. The contracts are the meeting.

Read [security](security.md) first. These steps move value once you broadcast. The commands below are the shape of the calls. They are not a recommendation to deploy, and they are not investment advice.

Compiler settings, if you verify or rebuild: solc **0.8.28**, optimizer **on**, **200** runs, EVM version **prague**, `via_ir` off. OpenZeppelin Contracts **v5.6.1**.

## 0. Nothing here broadcasts by itself

The forge scripts revert unless `DEPLOYER_PRIVATE_KEY` is set and `GV_CONFIRM` is the exact string named below. Foundry still only sends transactions if you add `--broadcast`. Leave the key out of git. Do not commit `.env`. Later `cast` examples use `$BASE_RPC_URL`. Set that to the same Anvil node or public testnet.

Copy `.env.example` to `.env` locally if you want. The example values for delays are starting points an issuer edits. They are not a default deployment.

Do not send any other transaction from the deployer key while `DeployInfrastructure` runs. The factory address is `CREATE` at nonce + 11.

The forge scripts call `GvChainGuard` before they read the key. Allowed chain ids are 31337 (Anvil), 1337, 84532 (Base Sepolia), 11155111 (Sepolia), 11155420 (OP Sepolia), 421614 (Arbitrum Sepolia), and 80002 (Polygon Amoy). Every other id reverts, including Ethereum mainnet and Base mainnet. There is no override. Point `--rpc-url` at Anvil (`http://127.0.0.1:8545`) or at a public testnet such as `https://sepolia.base.org`.

## 1. Deploy the factory and the directory

Once per chain is enough. Later issuers call the same factory. The directory is optional. Issuers who do not want it ignore that address.

```bash
export DEPLOYER_PRIVATE_KEY=0x…          # your key, never a committed value
export GV_CONFIRM=deploy-gv-infrastructure

forge script script/DeployInfrastructure.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

For Base Sepolia, use `--rpc-url https://sepolia.base.org`. The script reverts on Base mainnet.

The log lists the eleven deployers (`share`, `wrapper`, `timelock`, `governor`, `dividend`, `rules`, `assembly`, `information`, `terms`, `acquisition`, `recovery`), then `factory` and `directory`. Keep the deployer addresses. Verification needs them as the factory's constructor arguments, in that order.

Simulate first by omitting `--broadcast`. You still must set the key and `GV_CONFIRM`, because the script refuses to impersonate a default account.

## 2. Deploy an issuer kit

The broadcaster of this script is the issuer. A native share's initial supply is minted to that address. The factory does not become an admin.

`GV_TOKEN_MODE` is one of:

| Mode | What the governor votes on |
| --- | --- |
| `native` | A new `GvShare`. Set `GV_NAME`, `GV_SYMBOL`, `GV_DECIMALS` (0–18), `GV_SUPPLY`. |
| `wrap` | A new `GvVotesWrapper` around `GV_EXISTING_UNDERLYING`. Use this for a CMTAT v3 token. Set `GV_NAME` and `GV_SYMBOL`. Supply stays 0. Holders deposit later. |
| `votes` | `GV_EXISTING_VOTES`, which must already be ERC-5805 with `CLOCK_MODE` starting `mode=timestamp`. |

CMTAT v3 does not implement ERC-5805. Passing it as `votes` reverts. Wrap it.

```bash
export GV_CONFIRM=deploy-gv-kit
export GV_FACTORY=0x…                    # from step 1, on the same local node or testnet
export GV_TOKEN_MODE=native
export GV_NAME="Example Shares"
export GV_SYMBOL=EXS
export GV_DECIMALS=0
export GV_SUPPLY=1000
export GV_GOV_NAME="Example Governor"
export GV_VOTING_DELAY=86400             # seconds
export GV_VOTING_PERIOD=604800           # seconds
export GV_PROPOSAL_THRESHOLD=1
export GV_QUORUM_NUMERATOR=50            # percent. For + Abstain must reach this.
export GV_TIMELOCK_DELAY=172800          # seconds
export GV_METADATA_URI="ipfs://…"        # public description, max 1024 bytes
export GV_SALT=0x…                       # bytes32, chosen by the issuer

forge script script/DeployIssuerKit.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

### Full issuer set

`script/DeployIssuerSet.s.sol` calls `deploySet`. It deploys a native share plus the six rule modules in one transaction, wires the articles gate and the acquisition pointer, and clears the factory's one-time rights. It does not set the transfer policy or the share modules. Wrap mode and an existing votes token stay on the kit script above.

`GV_CONFIRM` is `deploy-gv-issuer-set`. `GV_CONSIDERATION` is an ERC-20 that already has code on that chain. The factory does not deploy it. The same chain guard applies.

```bash
export GV_CONFIRM=deploy-gv-issuer-set
export GV_CONSIDERATION=0x…              # existing ERC-20, not a wallet

forge script script/DeployIssuerSet.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

The script logs `predictSet` and reverts if `deploySet` disagrees. The factory also emits `IssuerSetDeployed` with the six module addresses.

`predict` uses the same issuer, spec, and salt. The script logs the predicted addresses and reverts the simulation if `deploy` disagrees. The factory emits:

```solidity
event IssuerKitDeployed(
    address indexed issuer,
    address share,
    address governor,
    address timelock,
    address dividend,
    string metadataURI
);
```

That event is the on-chain record of the meeting contracts. A directory entry is a separate, optional pointer.

### Optional directory

```bash
cast send "$DIRECTORY" \
  "register(address,address,address,address,string)" \
  "$SHARE" "$GOVERNOR" "$TIMELOCK" "$DIVIDEND" "$GV_METADATA_URI" \
  --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY"
```

Only that issuer, or the timelock stored on the entry, can `update` it. The governor never reads the directory. Anyone can `get(issuer)`. An entry does not prove the factory deployed those addresses. Compare them with `IssuerKitDeployed`.

## 3. Delegate

Votes start at zero until a holder delegates. For a native share, the issuer does this before proposing. Wait until the next second. The governor checks the proposer's votes at `clock() - 1`.

```bash
cast send "$SHARE" "delegate(address)" "$HOLDER" \
  --rpc-url "$BASE_RPC_URL" --private-key "$HOLDER_KEY"
```

For a wrapper, the holder `approve`s the wrapper for the underlying, calls `depositFor(holder, amount)`, then `delegate`.

## 4. Propose

Encode the action the timelock should take. A dividend epoch is one example. A share mint or a settings change is the same shape. `targets`, `values`, and `calldatas` are parallel arrays. `values` is zero unless the timelock must forward ETH.

```bash
CALLDATA=$(cast calldata \
  "startDistribution(address,bytes32,uint256,uint64,string)" \
  "$USDC" "$ROOT" "$TOTAL" "$DEADLINE" "ipfs://tree")

cast send "$GOVERNOR" \
  "propose(address[],uint256[],bytes[],string)" \
  "[$DIVIDEND]" "[0]" "[$CALLDATA]" "Dividend for the period ending …" \
  --rpc-url "$BASE_RPC_URL" --private-key "$PROPOSER_KEY"
```

`$DEADLINE` is a unix time. Claims are allowed through that second. The proposal description is hashed into the proposal id. Keep the exact string. You will pass it to `queue` and `execute`.

The proposal is `Pending` until `votingDelay` seconds have passed, then `Active` until `votingPeriod` seconds after the snapshot.

### Tally

The governor is the OpenZeppelin wizard set: `Governor`, `GovernorSettings`, `GovernorCountingSimple`, `GovernorVotes`, `GovernorVotesQuorumFraction`, `GovernorTimelockControl`. Tally indexes that interface (`propose`, `castVote`, `queue`, `execute`, `state`, `quorum`, `votingDelay`, `votingPeriod`, `proposalThreshold`, `name`, `version`, `COUNTING_MODE`, `CLOCK_MODE`, `timelock`). Add the governor by address on the chain where you deployed it. The clock is a timestamp, not a block number. If a particular Tally deployment has not indexed timestamp clocks, vote with `cast` instead. The contracts do not depend on Tally.

`COUNTING_MODE` is `support=bravo&quorum=for,abstain`. Support values: `0` Against, `1` For, `2` Abstain.

## 5. Vote

After the snapshot (`proposalSnapshot` plus one second is a safe time):

```bash
cast send "$GOVERNOR" "castVote(uint256,uint8)" "$PROPOSAL_ID" 1 \
  --rpc-url "$BASE_RPC_URL" --private-key "$HOLDER_KEY"
```

Voting weight is the delegated balance at the snapshot, not the balance at the time of the vote. For must be strictly greater than Against, and For + Abstain must reach quorum, or the proposal is `Defeated`.

## 6. Queue and execute

After `proposalDeadline`:

```bash
DESC=$(cast keccak "Dividend for the period ending …")

cast send "$GOVERNOR" \
  "queue(address[],uint256[],bytes[],bytes32)" \
  "[$DIVIDEND]" "[0]" "[$CALLDATA]" "$DESC" \
  --rpc-url "$BASE_RPC_URL" --private-key "$ANY_KEY"

# wait until proposalEta, which is the queue time plus the timelock delay
cast send "$GOVERNOR" \
  "execute(address[],uint256[],bytes[],bytes32)" \
  "[$DIVIDEND]" "[0]" "[$CALLDATA]" "$DESC" \
  --rpc-url "$BASE_RPC_URL" --private-key "$ANY_KEY"
```

Anyone can call `queue` and `execute` on the governor. The timelock accepts the governor contract as executor, not the caller. `state` becomes `Executed`. The proposer can `cancel` only while the proposal is still `Pending`.

Changing `votingDelay` is a proposal whose target is the governor and whose calldata is `setVotingDelay(uint48)`. The same pattern mints shares: target the share, calldata `mint(address,uint256)`.

## 7. Build the tree, fund, claim, sweep

`script/build_merkle.py` needs `cast` on `PATH`. Amounts are integer units of the funding token. USDC on Base has 6 decimals, so one USDC is `1000000`. Indexes are `0..n-1` with no gaps and no duplicates. Accounts are the holders who should receive the tokens.

```bash
cat <<'JSON' | python3 script/build_merkle.py > tree.json
{"claims":[
  {"index":0,"account":"0x…","amount":"1000000"},
  {"index":1,"account":"0x…","amount":"2500000"}
]}
JSON
```

The output `root` and `total` are the arguments to `startDistribution`. Publish the JSON (for example on IPFS) and pass that URI as the metadata. The contract does not fetch it. The leaf is:

```text
keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))
```

Pairs are sorted. An odd node is promoted. This matches `GvDividend.hashLeaf` and OpenZeppelin's sorted merkle proof.

After the proposal has executed, anyone can fund. Claims stay closed until the contract has received `total`.

```bash
cast send "$USDC" "approve(address,uint256)" "$DIVIDEND" "$TOTAL" \
  --rpc-url "$BASE_RPC_URL" --private-key "$PAYER_KEY"
cast send "$DIVIDEND" "fund(uint256,uint256)" 0 "$TOTAL" \
  --rpc-url "$BASE_RPC_URL" --private-key "$PAYER_KEY"
```

On Base, canonical USDC is `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`. That is the token contract, not a wallet. A fee-on-transfer token will revert.

A holder, or anyone, submits that holder's proof. The transfer goes to `account`, not to `msg.sender`.

```bash
cast send "$DIVIDEND" \
  "claim(uint256,uint256,address,uint256,bytes32[])" \
  0 0 "$ACCOUNT" "$AMOUNT" "[0x…,0x…]" \
  --rpc-url "$BASE_RPC_URL" --private-key "$ANY_KEY"
```

After `deadline`, a second proposal calls `sweep(epoch, to)` on the dividend. Only the timelock can sweep, and only once. The amount is `funded - claimed`. Tokens that someone transferred in without calling `fund` are not part of that amount. The timelock can recover them with `recoverSurplus(token, to)`, which sends `balance - reserved` and cannot take a funded epoch's remaining tokens.

## 8. Verify on a testnet explorer and Sourcify

Verify the exact compiler settings above. A mismatch of optimizer runs or EVM version produces different bytecode. The commands below use Base Sepolia, chain id 84532, which is a chain the scripts allow. They do not target chain id 8453.

```bash
FACTORY_ARGS=$(cast abi-encode \
  "constructor(address,address,address,address,address,address,address,address,address,address,address)" \
  "$SHARE_DEPLOYER" "$WRAPPER_DEPLOYER" "$TIMELOCK_DEPLOYER" \
  "$GOVERNOR_DEPLOYER" "$DIVIDEND_DEPLOYER" \
  "$RULES_DEPLOYER" "$ASSEMBLY_DEPLOYER" "$INFORMATION_DEPLOYER" \
  "$TERMS_DEPLOYER" "$ACQUISITION_DEPLOYER" "$RECOVERY_DEPLOYER")

forge verify-contract \
  --chain 84532 \
  --verifier etherscan \
  --etherscan-api-key "$BASESCAN_API_KEY" \
  --compiler-version 0.8.28 \
  --optimizer-runs 200 \
  --watch \
  "$FACTORY" \
  src/GvKitFactory.sol:GvKitFactory \
  --constructor-args "$FACTORY_ARGS"
```

Each deployer takes the factory address as its only constructor argument:

```bash
forge verify-contract --chain 84532 --verifier etherscan \
  --etherscan-api-key "$BASESCAN_API_KEY" \
  --compiler-version 0.8.28 --optimizer-runs 200 --watch \
  "$SHARE_DEPLOYER" \
  src/deployers/GvDeployers.sol:GvShareDeployer \
  --constructor-args "$(cast abi-encode "constructor(address)" "$FACTORY")"
```

Repeat for `GvVotesWrapperDeployer`, `GvTimelockDeployer`, `GvGovernorDeployer`, and `GvDividendDeployer` in that file, and for `GvCompanyRulesDeployer`, `GvAssemblyDeployer`, `GvInformationDeployer`, `GvShareTermsDeployer`, `GvAcquisitionDeployer`, and `GvRecoveryDeployer` in `src/deployers/GvModuleDeployers.sol`.

The kit contracts are created by those deployers. Verify each with the constructor arguments that were used:

| Contract | Path | Constructor |
| --- | --- | --- |
| `GvShare` | `src/GvShare.sol:GvShare` | `(string,string,uint8,address,uint256,address)` name, symbol, decimals, issuer, supply, timelock |
| `GvVotesWrapper` | `src/GvVotesWrapper.sol:GvVotesWrapper` | `(address,string,string,address)` underlying, name, symbol, timelock |
| `GvGovernor` | `src/GvGovernor.sol:GvGovernor` | `(string,address,address,uint48,uint32,uint256,uint256)` name, votes token, timelock, delay, period, threshold, quorum numerator |
| `GvDividend` | `src/GvDividend.sol:GvDividend` | `(address)` timelock |
| `GvDirectory` | `src/GvDirectory.sol:GvDirectory` | none |
| `TimelockController` | `lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController` | `(uint256,address[],address[],address)` min delay, empty proposers, empty executors, factory |

The timelock's constructor admin was the factory. The factory renounced that role in the same `deploy` transaction. The verified source still shows the constructor argument. The live role is on the timelock itself. Check `hasRole(DEFAULT_ADMIN_ROLE, factory)` is false.

Sourcify uses the same artifacts. Swap the verifier:

```bash
forge verify-contract \
  --chain 84532 \
  --verifier sourcify \
  --compiler-version 0.8.28 \
  --optimizer-runs 200 \
  "$FACTORY" \
  src/GvKitFactory.sol:GvKitFactory \
  --constructor-args "$FACTORY_ARGS"
```

If a verifier asks for the EVM version, it is `prague`.

## 9. What you can read on-chain without an account

- `IssuerKitDeployed` and `IssuerSetDeployed` logs on the factory, and `deploymentByGovernor(governor)`.
- `governor.timelock()`, `votingDelay()`, `votingPeriod()`, `quorumNumerator()`, `proposalThreshold()`, `state(id)`, `proposalVotes(id)`.
- `dividend.distribution(epoch)` and `isClaimed(epoch, index)`.
- `directory.get(issuer)`, if someone registered.

No InvestHub API is required for any of those reads.

## 10. Articles, invitations, and share terms

The governor is still the ballot. `deploySet` creates the extra contracts and points the governor at the assembly and the terms at the acquisition. It does not set the share token's policy. Only the timelock can call `setTransferPolicy` and `setShareModule`, which means an executed proposal.

`script/DeployIssuerTerms.s.sol` is the path for a kit that was created with `deploy` (wrap mode, an existing votes token, or a kit deployed before `deploySet`). It runs only when `GV_CONFIRM` is `deploy-gv-terms` and you pass `--broadcast` yourself. The same chain guard applies. It does not set the share token's policy either.

Until that proposal, the share token transfers as before. After it, a recipient needs to be whitelisted and to have accepted the current SHA hash, by `acceptSha`, by a relayed EIP-712 signature, or by a Merkle proof that stores the same acceptance. A mint and a transfer from the configured treasury skip pre-emption and emit `PrimaryIssuance`. Read [legal-wrapper.md](legal-wrapper.md) before treating any stored number as a statutory figure. The defaults are placeholders.

An off-chain notifier subscribes to `InvitationNotice` on `GvAssembly`. The log has the meeting type, the notice deadline, the invitation hash, and an optional CID. It has no email address. The notifier looks up holders from the share token and addresses from the company's own register. The meeting can be opened by anyone after the notice, whether or not a mail was sent.

`GvCompanyRules`, `GvAssembly`, and `GvShareTerms` are owned by the broadcaster of the terms script. Transfer that ownership to the timelock if a single key should not be able to retune quorums, directors, or the whitelist. `GvAcquisition` has no owner. `GvRecovery` proposes transfers only through directors, and only after the delay.
