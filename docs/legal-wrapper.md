# Legal wrapper

**These contracts are unaudited.** This page is an engineering note. It is not legal advice, not a statement of Liechtenstein or Swiss law, and not a claim that any number in the code is the number a statute requires.

The kit keeps the OpenZeppelin governor as the ballot. The contracts added here are the issuer's own parameter store, meeting record, information record, and share terms. InvestHub is not an owner, not a module, and not a party. Nothing in them reads `GvDirectory`. A meeting, a transfer, a drag, and a recovery can be sent from any wallet that can call the chain.

## What "articles as code" means here

A Liechtenstein company still has articles (Statuten) and, if the shareholders use one, a shareholder agreement (SHA). Those documents stay the legal text. The contracts are the mechanism the documents can point at.

The intended wrapper, which counsel has to write in a form the register and a notary will accept, is:

1. The articles name the deployed addresses: share, governor, timelock, `GvCompanyRules`, `GvAssembly`, `GvInformation`, `GvShareTerms`, `GvAcquisition`, `GvRecovery`.
2. The articles say that the parameters stored in `GvCompanyRules` are the company's figures for notice, convening, quorum, majority, board size, and capital, **after** a lawyer has replaced the software placeholders.
3. The SHA names `shaHash` and `shaVersion` on `GvShareTerms`. The binding text is the off-chain document with that keccak256. A later version is binding only once published on-chain, and a recipient must accept the current version before the share token will mint or transfer shares to them.
4. A hash on-chain is a commitment to a document that lives off-chain. The document should be encrypted if it is confidential. The chain does not see the plaintext and does not store an email address.

`GvCompanyRules.canonicalOutcome` is the function the articles reference. `GvAssembly.articlesOutcome` calls it and does not keep a second formula. `passed` follows `bindingMode`:

- `Articles` (the default). Participation (For + Against + Abstain) meets the class quorum. For exceeds the class majority of For + Against. Abstain is outside that majority denominator.
- `Governor`. The same shape as the governor's counter: For + Abstain meets the class quorum, and For is strictly greater than Against. The basis points are the class rule, not the governor contract's single percent numerator.
- `Both`. Both formulas have to succeed.

`GvGovernor` is unchanged. It is the execution gate Tally indexes, with one quorum numerator for every proposal. It does not read the rules. A proposal can reach `Executed` there while `passed` is false. The binding mode records which check the articles adopt. It does not stop the timelock. A statute change that must be stricter than the governor's single quorum should be treated as passed only when `articlesOutcome` says `passed`.

## Placeholders

Every number `GvCompanyRules` stores at deployment is a **placeholder**. The constants are named `PLACEHOLDER_*`. They are not a reading of the Personen- und Gesellschaftsrecht (PGR), the TVTG, or of any real articles. The empty capital-band list is intentional. A comment in the source mentions "3 directors once capital is at least 1,000,000" only as the shape of a band an issuer may configure. Shipping that band as a default would pretend to state a rule this repository does not know.

Software bounds are labeled as software bounds. The recovery delay cannot be set below seven days, so a compromised owner cannot turn the delay off. Seven days is not a claim about a statutory waiting period. A lawyer may require a longer one. The configurable default is thirty days, and that thirty days is also a placeholder.

The unclaimed-drag window cannot be set below 180 days or above 1,825 days. Those are software bounds, not a statute. The placeholder default is 365 days. Until the owner sets `unclaimedRecipient`, the redirect does nothing and holders can keep claiming.

## Meetings

`GvAssembly` records an AGM or an EGM.

- A director can convene while `directorCount` is at least `requiredDirectors()`. If a capital band has raised the floor and the board is short, the board cannot convene. Shareholders still can, which is how a short board gets a meeting that can appoint directors.
- One holder can convene when their current balance meets `meetingCallThresholdBps` of supply, rounding the threshold up. That path reads the live balance. One balance cannot be pledged twice. A flash loan of tokens can still meet it if transfers are open.
- Holders under that fraction file a request. Support is each supporter's ERC-20 Votes weight at the second before the request was filed, added once into a running tally. There is no cap on the number of supporters. A transfer after the snapshot does not drop the original supporter and does not count for the recipient. Undelegated shares weigh zero, so they count as absent. The initiator is not counted until they support.
- The notice period is copied onto the meeting. A later change to the rules does not shorten a notice already given. `openMeeting` reverts until `noticeDeadline`.
- The agenda is stored on-chain: a short title, a document hash, and a resolution class. The invitation is a `bytes32` hash plus an optional CID of at most 128 bytes.

`InvitationNotice` is the log an off-chain notifier turns into email. It carries the meeting id, the type, the convener, the deadline, the hash, the CID, and the agenda hash. It does not carry a mailbox. The notifier joins the log to holders by reading the share token, and to email addresses by reading the company's own register off-chain. If the notifier is down, the meeting is still on-chain. Anyone can read `meeting` and `agendaItem` and call `openMeeting` after the notice.

## Information duties

`GvInformation` records duties and requests. A director schedules a publication by a kind (a `bytes32` label the company chooses, for example the hash of `"ANNUAL_REPORT"`) and a deadline, then fulfils it with a document hash. A shareholder with a non-zero balance files a request. That starts `responseWindow`. Overdue ids are paged by `overduePublications` and `overdueRequests`. `notifyPublicationOverdue` and `notifyResponseOverdue` emit a reminder without changing rights.

The contract has no field for a document body. Put the ciphertext at the CID. Hash the bytes you store.

## Share terms

Until the timelock calls `GvShare.setTransferPolicy`, the share token behaves as it did before this change. After the policy is set:

- The recipient must be on the whitelist and must have `acceptedVersion == shaVersion`.
- A holder records that acceptance by calling `acceptSha`, by signing the EIP-712 `AcceptSha(address account,uint256 version,bytes32 shaHash)` digest (domain name `GvShareTerms`, version `1`) so a relayer can submit it, or by a Merkle proof against the root the terms owner published for this version. The leaf is `keccak256(bytes.concat(keccak256(abi.encode(account, shaVersion, shaHash))))`, pairs are sorted, and an odd node is promoted. The signature is the holder's own proof. The root is the owner's list of accounts that accepted off-chain. Both paths write `acceptedVersion` and emit `ShaAccepted` for that account. A new SHA version clears the root.
- The whitelist can be written in a batch of at most 64 accounts. The same bound applies to a batch of signatures or proofs.
- A lock-up blocks that holder from starting a transfer until the timestamp.
- If pre-emption is enabled, a direct peer transfer reverts. A mint, and a transfer from the configured `issuerTreasury`, do not. They still require the recipient's whitelist entry and current SHA acceptance. A treasury transfer also requires the treasury itself to be whitelisted, to hold the current SHA, and not to be locked. `PrimaryIssuance` records each of those transfers. The event is how a later reader tells a primary issue from a peer transfer.
- The seller escrows a pre-emption for `preEmptionWindow`. Other holders may buy up to a pro rata cap at the same price per token unit. The cap is `offer * holderBalance / baseSupply`, with `baseSupply` equal to supply minus the seller's balance at the start. Integer division can leave a remainder. The original buyer takes what is left after the window, or the seller takes it back.
- A stake that meets `tagThresholdBps` cannot use pre-emption. It has to be opened as a tag sale.

The whitelist is this token's list. It is not a copy of a CMTAT rule engine. A wrapped CMTAT keeps that engine on the underlying token.

The terms owner can freeze a transfer by taking someone off the whitelist or by setting a lock-up. The terms owner cannot move someone else's balance. That split is deliberate. Transfer ownership of `GvCompanyRules`, `GvAssembly`, and `GvShareTerms` to the kit timelock once the figures are the ones counsel signed, so a single issuer key cannot retune them.

## Drag-along and tag-along

`GvAcquisition` has no owner.

**Drag.** The buyer escrows the consideration token for `pricePerToken * totalSupply` and sets a quorum at least as high as `dragQuorumBps` (placeholder 7,500, meaning 75 percent). Holders accept by escrowing shares. The buyer's own holding counts toward that quorum. The count is the lesser of the balance recorded in `postDrag` and the buyer's live balance, so shares acquired after the offer do not inflate it and shares the buyer no longer holds drop out. The buyer cannot tender on top of that. This is what lets a buyer who already holds more than 25 percent still reach a 75 percent quorum: the other holders can accept the rest.

Once that sum was reached before the deadline and `executeDrag` has run, the offer is final. Transfers of the token stay frozen until the buyer holds the whole supply. Anyone may `claimDrag` for a holder. The currency is credited to that holder, pro rata at the offer price, and the shares move to the stored buyer. `pushDrag` does the same for at most 32 holders in one call, for a small cap table. There is no function that sends the shares to an address the caller chooses.

After `unclaimedWindow` (placeholder 365 days, and not on the deadline second itself), `redirectUnclaimed` credits a holder's unpaid consideration to `unclaimedRecipient` and still moves the shares to the buyer. The caller cannot pick a different recipient. If the recipient is unset, the redirect reverts and the holder can keep claiming. If the quorum is missed, or it was met and then the buyer's live balance falls below it before execution, the buyer can cancel and acceptors reclaim their shares. Peer transfers are paused from the moment the offer is posted.

`moduleTransfer` on the share token only succeeds when the module has armed that exact transfer, and only the timelock can add a module. A bound recovery module can still move shares during a drag, because that path skips the transfer policy. Moving shares onto the buyer does not raise the snapshot. Moving them off the buyer can drop the quorum before execution.

**Tag.** A sale at or above the threshold escrows the price of the seller's stake plus the maximum other holders could join. The join cap is the same fraction of each other holding that the seller is selling of their own holding. The sale can settle only after the window. Joining is a right, not a duty. Settlement without joiners is allowed once the window has run.

The drag path can move locked shares. The tag path and pre-emption cannot. Whether a drag should override a contractual lock-up is an open question for the SHA, listed below.

## Recovery

`GvRecovery` moves one balance, from one address, to one address, after a delay, and only if the proposal carries a non-zero `orderHash`.

- `courtOrder == false` is a board resolution. The affected holder, a director, or the timelock can cancel it before execution.
- `courtOrder == true` is a commitment to a court order. The holder cannot cancel it. A director or the timelock still can, before execution.
- The amount `0` means "whatever that address holds at execution." Any other amount is exact.
- A board-resolution recipient must be whitelisted and must have accepted the current SHA. A court-order recipient need not be.
- Execution needs `recoverySignatures` director signatures. The placeholder is 1. Raising it does not create a legal board; it is a parameter.

The contract does not check that the hash matches a real court file. The delay, the events (`RecoveryProposed`, `RecoveryExecuted`, `RecoveryCancelled`), and the timelock cancel are the on-chain limits. They are not a finding that a court would treat the hash as an order. A compromised issuer key that still owns the assembly can appoint a director and, after the delay, propose a court-order recovery. Transfer assembly ownership to the timelock if that key should not have that power. Even then, a director who already sits can propose, and holders have the delay in which to put a cancel through the timelock.

## Liechtenstein TVTG and the Swiss DLT ledger

These are pointers for counsel, not a legal opinion.

**Liechtenstein.** The Token- und VT-Dienstleister-Gesetz of 3 October 2019 (TVTG) is associated with a token-container model: a token can contain a right, and the right is defined by the legal instrument, not by the bytecode. An Aktie in an AG and a membership interest in a GmbH are different rights under the PGR. A GmbH transfer is often subject to approval and to form requirements that an ERC-20 call does not satisfy. This repository does not claim that deploying these contracts creates a token container, registers a VT service provider, or replaces a notarial deed or the Aktienbuch.

**Switzerland, and Aktionariat.** The Swiss DLT legislation introduced ledger-based securities (Registerwertrechte) into the Code of Obligations (art. 973d and following). Aktionariat's public documentation describes a Swiss pattern aimed at that regime: a token transfer can be the technical assignment, while shareholder rights against the company still depend on registration. Their current share and drag-along contracts are not the model this kit copies, for the licence reasons in the next section, and they solve a Swiss register question this kit does not claim to solve.

An issuer that wants Swiss ledger-based securities needs Swiss advice and a register that meets those statutory conditions. An issuer that is a Liechtenstein AG or GmbH needs the articles and the SHA to say, in the form Liechtenstein law requires, that these addresses and hashes are the mechanism for the matters the company is allowed to delegate to code.

## Aktionariat licence and what was reused

Reviewed from the public repository [github.com/aktionariat/contracts](https://github.com/aktionariat/contracts) on 15 November 2026.

| Source | Licence on the file that was read | Production use |
| --- | --- | --- |
| Root `LICENSE`, described as version 6 | Business Source License 1.1. Licensor: Aktionariat AG. Change date: 1 October 2030. Change licence: MIT. | The additional use grant allows production use where Aktionariat AG deployed the contracts or authorised the deployment. A third-party issuer deploying this kit is outside that grant. |
| `contracts/shares/sha/DragAlong.sol` | `SPDX-License-Identifier: BUSL-1.1` | Same restriction. This is the current acquisition-offer implementation. |
| `contracts/shares/base/Recoverable.sol` | `SPDX-License-Identifier: BUSL-1.1` | Same restriction. |
| `contracts/ERC20/ERC20Allowlistable.sol` | `SPDX-License-Identifier: BUSL-1.1` | Same restriction. |
| `archive/deployed-shares-v3` `DraggableShares.sol` and `Shares.sol` | `LicenseRef-Aktionariat`: "MIT License with Automated License Fee Payments." The grant requires that the automated fee payments built into the software are preserved. | Not a fee-free MIT licence. Copying the code and removing the fee would break the grant. Paying a fee to a third party also fights this kit's rule that the issuer's contracts do not embed an outside claim. |

Their README says some files (the `EIP7702` folder, interfaces, `ERC20Flaggable`, and upstream OpenZeppelin or Uniswap code) are MIT, and that `DirectInvestment` and `SecondaryMarket` use the fee-preserving Aktionariat licence. Those MIT files are not the drag, tag, recovery, or allowlist design.

**Decision: reimplement. No Aktionariat source is copied or adapted.** The public docs were used for the design comparison below. Function names, thresholds, and control flow in this repository are written for the behaviour this kit was asked to enforce.

### Comparison

| Concern | Aktionariat public design | This kit | Why it differs |
| --- | --- | --- | --- |
| Share token | `Shares`, then a 1:1 SHA wrapper | Existing `GvShare` (ERC-20 votes, timestamp clock). Optional policy hook. | Their token code is BUSL or fee-bearing. The governor needs ERC-5805. The hook is off until the timelock sets it. |
| SHA binding | Wrapper token. Holding the wrapper is holding the agreement. | `shaHash`, `shaVersion`, and `acceptSha` on `GvShareTerms`. Receiving shares requires the current version. | Reimplemented. The legal text stays off-chain. The chain stores the commitment and the acceptance. |
| Drag-along | `offerAcquisition`. Veto for 20 days by the issuer or a holder above 10 percent of wrapped supply. At execution the buyer pays `price * totalSupply` and the wrapper's base becomes the currency. | Buyer escrows the full consideration first. The buyer's existing holding counts toward the quorum, capped by the balance at posting. After the quorum, each holder pulls the same price from escrow. A push is bounded at 32 holders. | The veto-and-wrapper-swap code is BUSL and was not copied. The acceptance quorum, the up-front escrow, and the pull claim are the behaviour this kit was asked to ship. The shared idea is the public one: one price, every holder, no silent admin transfer. |
| Tag-along | Their drag-along note says they do not automate tag-along, because a token transfer is not always a sale and the price is not on-chain. | An explicit sale. Below the threshold, pre-emption. At or above it, the same price must be open to other holders pro rata before settlement. | There was no tag-along implementation to reuse. The sale is a function call, not every `transfer`. |
| Recovery | Holder-initiated claim, long delay, the holder can veto, the issuer can cancel. Their note cites a Swiss waiting-period analogy. | A director proposes. The call carries a hash of a board resolution or of a court order. Delay cannot be zero. The holder can cancel a board resolution only. | Their recovery code is BUSL. The path here is the one requested: board or court hash, events, delay, and no general admin transfer. |
| Allowlist | `ERC20Allowlistable` (BUSL). | Boolean whitelist on `GvShareTerms`, set by the terms owner. | Reimplemented. |
| Factory | Their factory. | `GvKitFactory` unchanged. The new modules are deployed by the issuer and wired by the timelock. | Their factory is not used. InvestHub still has no role. |
| Meeting | Not part of their share contracts. | OpenZeppelin governor, unchanged, plus `GvAssembly`. | The ballot stays the wizard-shaped governor. |

## Open questions for Liechtenstein counsel

1. For this AG, and separately for this GmbH, which PGR clauses and which articles actually set quorum, majority, notice, and who may convene? Replace every `PLACEHOLDER_*` value. Do not leave the software defaults in a live company.
2. Can a GmbH membership interest be moved by an ERC-20 transfer at all, or does the PGR still require approval, a deed, or a notarial form that this call cannot replace?
3. Does the TVTG token-container model require anything this deployment does not do (a prospectus, a physical validator, a VT service-provider registration, a particular register entry)?
4. Is an on-chain `acceptSha`, an EIP-712 signature relayed by the issuer, or inclusion in the issuer's Merkle root a sufficient form of adherence to the SHA, or do the articles and the SHA need a signed deed as well? The Merkle root is the owner's attestation. The signature is the holder's.
5. Is the pre-emption cap (current balance over the seller's starting base, integer division, buyer excluded from the exercise and given the remainder) the pre-emption the SHA describes?
6. Is the tag-along fraction "the same fraction of each other holding" the clause the shareholders want, or is it a right to sell their entire holding?
7. Is 75 percent the drag quorum the SHA should state? The code will refuse a lower offer quorum than `dragQuorumBps`, but the stored figure is a placeholder.
8. Can a drag-along force a transfer the PGR would treat as needing consent, a squeeze-out proceeding, or a resolution the governor must have already executed?
9. Should a drag override a lock-up? The code does. Pre-emption and tag-along do not.
10. Is the recovery delay long enough, and is an unverified keccak256 of a PDF an acceptable commitment to a board resolution or a court order? Who may cancel a court-order path?
11. Should `GvCompanyRules`, `GvAssembly`, and `GvShareTerms` be owned by the timelock from the first day, so the issuer key cannot retune quorums, directors, or the whitelist?
12. Do the information-request and publication windows match the company's Auskunftspflichten, and is a hash of ciphertext enough to perform them?
13. `bindingMode` defaults to `Articles`. `Governor` uses the governor's counting shape at the class basis points. `Both` requires both formulas. The governor contract can still execute a proposal the articles do not treat as passed. Which mode does this company adopt, and should the governor's percent numerator be set beside the class basis points?
14. Undelegated shares do not show up in the governor's vote weights. Do the articles count them as absent?
15. The Aktienbuch, tax, and stamp duty stay off-chain. Who writes the register entry after a transfer, a drag, or a recovery?

Draft clauses that name the addresses are in [templates/articles-draft.md](templates/articles-draft.md) and [templates/sha-draft.md](templates/sha-draft.md). They are drafts for a lawyer to rewrite.
