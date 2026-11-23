# Modules

The rule modules are part of the issuer set. `deploySet` creates them in the same transaction as the share, the ballot, and the dividend, and wires two pointers. The issuer owns the three Ownable modules. InvestHub is not an owner and cannot call those functions.

The contracts are unaudited. Every `PLACEHOLDER_*` constant is a software default. It is not a clause of the Liechtenstein Persons and Companies Act (PGR) and it is not a clause of the TVTG. A lawyer replaces the stored numbers before a company relies on them. The open questions for that review are in the repository file `docs/legal-wrapper.md`.

## What the factory wires, and what it leaves alone

| Pointer | Set by `deploySet` | Still unset |
| --- | --- | --- |
| Governor articles gate | Yes. The gate is the new `GvAssembly`. | |
| Terms acquisition | Yes. `GvShareTerms` points at the new `GvAcquisition`. | |
| Share transfer policy | | Unset. Transfers do not call `GvShareTerms` until the timelock calls `setTransferPolicy`. |
| Share modules | | Unset. A drag or a recovery cannot force a transfer until the timelock calls `setShareModule`. |

Those two timelock calls happen only through an executed proposal. The factory cannot make them.

## Company rules

`GvCompanyRules` stores quorum and majority for an ordinary class and a qualified class, notice periods for an AGM and an EGM, the fraction of voting power that can convene a meeting, the drag quorum, the tag-along threshold, and the recovery delay. The owner is the issuer until ownership moves to the timelock.

The constructor writes the placeholders, including a 14-day AGM notice, a 7-day EGM notice, and a 75 percent drag figure. Those figures are labelled `PLACEHOLDER_` in the source so a reader does not mistake them for a statute. Changing them is an owner call, which should be the timelock once counsel has signed the real numbers.

## Share terms

`GvShareTerms` holds the whitelist, the current SHA hash and version, lock-ups, and pre-emption. Receiving shares, once the policy is set, requires the whitelist and acceptance of the current SHA version. Acceptance is `acceptSha`, a relayed EIP-712 signature, or a Merkle proof that stores the same acceptance. The legal text stays off-chain. The chain stores the hash and the acceptance.

A mint, and a transfer from the configured treasury, skip pre-emption. A peer transfer does not.

## Acquisition

`GvAcquisition` has no owner. A buyer posts an offer and escrows the consideration token. The buyer's existing holding counts toward the drag quorum, capped by the balance at posting, and is not counted twice. After the quorum, each holder pulls the same price. A push settles at most 32 holders. Unclaimed currency can be redirected to the recipient on the company rules after the stored window.

Tag-along is an explicit sale, not every token transfer. Below the threshold, pre-emption applies. At or above it, the same price is opened to other holders pro rata before settlement.

Shares move to the buyer only when the timelock has set this contract as a share module, and only for the buyer who escrowed.

## Recovery

`GvRecovery` has no owner. A director proposes one delayed transfer and attaches a hash of a board resolution or of a court order. The delay cannot be zero. The contract does not check the document behind the hash. The holder can cancel a board-resolution path. A court-order path is not a holder veto. The timelock can cancel either. Execution waits out the delay, and it reverts while a drag is unsettled.

## Information duties

`GvInformation` has no owner. A director schedules a publication and later stores the document hash. A shareholder files a request. The contract records deadlines and exposes overdue items. It does not store the document, and it does not email anyone.

## Aktionariat

The public description of Aktionariat's share, drag, tag, and recovery behaviour was used as a design comparison. Their implementation was not copied. Function names, thresholds, and control flow in this kit are written for the behaviour this repository was asked to enforce. The comparison table is in `docs/legal-wrapper.md`.
