# Factory

`GvKitFactory` deploys an issuer's contracts with CREATE2. The issuer calls it. The factory stores the deployment and keeps no role.

The contracts are unaudited. These steps are the shape of a deployment. They are not a recommendation to deploy, and they are not investment advice.

## What one transaction deploys

`deploySet` is one transaction from the issuer. It creates:

| Contract | Role after the transaction |
| --- | --- |
| `GvShare` | Native share. The initial supply is minted to the issuer. Later minting is the timelock, after a vote. |
| `TimelockController` | Admin of itself. The governor is proposer, executor, and canceller. The factory renounces the temporary admin it used to grant those roles. |
| `GvGovernor` | The ballot. Token holders who have delegated. |
| `GvDividend` | Merkle epochs. The timelock opens an epoch and, after the deadline, sweeps what was not claimed. |
| `GvCompanyRules` | Owned by the issuer. |
| `GvAssembly` | Owned by the issuer. The meeting record. The governor stays the ballot. |
| `GvInformation` | No owner. Directors publish hashes. Shareholders file requests. |
| `GvShareTerms` | Owned by the issuer. Whitelist, SHA hash, lock-ups, pre-emption. |
| `GvAcquisition` | No owner. Drag-along and tag-along. |
| `GvRecovery` | No owner. One delayed transfer, proposed by a director. |

In that same transaction the factory points the governor at the assembly (`setArticlesGate`) and points the terms at the acquisition (`setAcquisition`). It then clears both one-time wiring rights. It does **not** set the share token's transfer policy, and it does **not** set share modules. Those stay unset until the timelock sets them through an executed proposal. Until that proposal, transfers do not call the terms.

`deploySet` is the native-share path. The consideration token (the ERC-20 used to escrow a sale) must already exist. The factory does not deploy it. Wrap mode and an existing votes token stay on `deploy`, which creates the share or wrapper, the timelock, the governor, and the dividend, and leaves the modules unset. Those tokens are not a `GvShare`, and the rule modules are typed to `GvShare`.

`GvDirectory` is optional and ownerless. It is not part of `deploySet`. A directory entry is a pointer the issuer writes later. It is not proof that the factory deployed those addresses. The factory events are the record: `IssuerKitDeployed` and `IssuerSetDeployed`.

## Deterministic addresses

`predictSet` returns the same addresses as `deploySet` for the same issuer, share spec, governance spec, consideration token, and salt. The salt is combined with the issuer, so two issuers can reuse a salt. The same issuer cannot reuse a salt: the second create reverts.

The factory itself is not CREATE2. Eleven small deployer contracts are created first, then the factory, because EIP-3860 limits a contract's initcode to 49,152 bytes. Each deployer can be called only by the factory. The factory address is the deployer's `CREATE` at nonce + 11. Send no other transaction from that key while the infrastructure script runs.

`KIT_VERSION` is `"2"`.

## Who holds the keys

The caller of `deploySet` is the issuer. The factory does not retain:

- the timelock `DEFAULT_ADMIN_ROLE` (it renounces it in the same transaction; the timelock holds that role on itself)
- the governor's one-time articles wirer
- the terms' one-time acquisition binder
- any share-module or transfer-policy right

There is no InvestHub admin key in the constructor and no function that grants one later.

After deployment, the issuer still owns `GvCompanyRules`, `GvAssembly`, and `GvShareTerms`. Transfer that ownership to the timelock if a single key should not be able to retune quorums, directors, or the whitelist. Counsel replaces the placeholder numbers first. See [Modules](./modules).

## Scripts stay on local nodes and public testnets

`script/DeployInfrastructure.s.sol` deploys the eleven deployers, the factory, and the optional directory. `script/DeployIssuerSet.s.sol` calls `deploySet`. Both revert unless `GV_CONFIRM` is the exact string for that script, and Foundry sends transactions only when you pass `--broadcast`.

Both scripts call `GvChainGuard`. It allows chain ids 31337 (Anvil), 1337, 84532 (Base Sepolia), 11155111 (Sepolia), 11155420 (OP Sepolia), 421614 (Arbitrum Sepolia), and 80002 (Polygon Amoy). Every other chain id reverts, including Ethereum mainnet and Base mainnet. There is no override.

```bash
anvil --gas-limit 40000000
# set DEPLOYER_PRIVATE_KEY locally; do not commit it
export GV_CONFIRM=deploy-gv-infrastructure
forge script script/DeployInfrastructure.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

`deploySet` itself uses about 23 million gas (a local receipt used 23,036,196; the Foundry gas-report median on the suite is 23,095,812). That fits under a 25 million gas block when the transaction gas limit is close to the gas used. Foundry's script estimate for the broadcast is higher than the gas used, and Anvil's default block gas limit of 30 million rejects that estimate. Start Anvil with `--gas-limit 40000000`.

A chain that enforces the EIP-7825 per-transaction cap of 16,777,216 gas cannot include `deploySet`. The scripts already refuse mainnet. On such a chain, deploy the kit with `deploy` and the modules with `script/DeployIssuerTerms.s.sol` instead of one `deploySet` transaction.

A public Base Sepolia endpoint is `https://sepolia.base.org`. Omit `--broadcast` to simulate. The script still refuses to impersonate a default account, so the key and `GV_CONFIRM` are required even for a simulation.

`GV_CONSIDERATION` on the issuer-set script is the existing ERC-20. Confirmation string: `deploy-gv-issuer-set`.

The full command list, the environment variables, and the verification constructor arguments are in the repository guide `docs/gv-without-investhub.md`.
