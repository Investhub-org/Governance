# Draft articles clauses

**DRAFT. Not legal advice. Requires review by a Liechtenstein lawyer.**

This is an English clause list for counsel. The operative articles of a Liechtenstein AG or GmbH are normally German, in the form the PGR and the notary require. Nothing below is a finished Satzung. Blanks in square brackets are for the company and for counsel. Do not treat a software placeholder in `GvCompanyRules` as if it were already the article.

The company is **[AG / GmbH — choose one. The transfer rules are not the same.]**

## Token and contracts

The membership rights designated **[share class]** are recorded in the share token at **[GvShare address]** (the "Share Token"). The following contracts, deployed by the company and not by any platform operator, are the technical mechanism for the matters these articles assign to them:

| Role | Address |
| --- | --- |
| Governor (ballot) | [GvGovernor] |
| Timelock | [TimelockController] |
| Company rules | [GvCompanyRules] |
| General meeting record | [GvAssembly] |
| Information record | [GvInformation] |
| Share terms and SHA commitment | [GvShareTerms] |
| Drag-along and tag-along | [GvAcquisition] |
| Recovery | [GvRecovery] |
| Dividend distributor, if used | [GvDividend] |

No platform operator, including any operator of a user interface, has an admin role on these contracts. The contracts remain usable if that interface is unavailable. A directory entry, if any, is not required and is not proof of these addresses. The company's record of the addresses is this article, as amended.

Counsel must decide whether the Share Token is the Aktienbuch, evidence for the Aktienbuch, or only a technical mirror. This draft does not make that decision.

## Parameters

The figures for notice, the fraction of capital that may convene a meeting, ordinary and qualified quorum and majority, the minimum number of directors, capital bands, the drag-along quorum, the tag-along threshold, the pre-emption window, the information-response window, and the recovery delay are the values stored in the company-rules contract.

At deployment those values are software placeholders. They are not adopted by these articles. Before the articles are passed, the company replaces each placeholder with the figure counsel confirms against the PGR and against these articles, and records the transaction hashes here:

| Parameter | Adopted value | Transaction |
| --- | --- | --- |
| Ordinary quorum and majority | [ ] | [ ] |
| Qualified quorum and majority (statute change) | [ ] | [ ] |
| AGM notice | [ ] | [ ] |
| EGM notice | [ ] | [ ] |
| Convening threshold | [ ] | [ ] |
| Minimum directors, and any capital band | [ ] | [ ] |
| Share capital figure and currency label | [ ] | [ ] |
| Drag-along quorum | [ ] | [ ] |
| Tag-along threshold | [ ] | [ ] |
| Recovery delay and required director signatures | [ ] | [ ] |

A change to those parameters after adoption is a **[ordinary / qualified]** resolution, executed through the timelock. Ownership of the company-rules contract is held by **[the timelock / other]**.

## Meetings

An annual general meeting and an extraordinary general meeting are convened through the general-meeting contract, as an AGM or an EGM.

The board may convene when the number of directors meets the minimum stored in the company-rules contract. Shareholders may convene when one holder, or holders acting together, meet the convening threshold stored there. Support is measured at the time of convening.

The notice period stored for that meeting type runs before the meeting can be opened. The notice is the `InvitationNotice` event: the invitation document hash, the optional content locator, and the agenda hash. Email is sent by the company from its own register. Failure of an email does not cancel a notice that was recorded on-chain.

The agenda stored on-chain is the agenda. Each item has a document hash and a class, ordinary or qualified.

A resolution is passed under these articles only when `articlesOutcome` on the meeting contract reports that the quorum and the majority for that item's class were met. The governor's own quorum is **[adopted as well / not sufficient on its own]**. Counsel fills this sentence. Undelegated shares **[count as absent / are treated as follows: …]**.

## Board

The company has at least the number of directors returned by `requiredDirectors` on the company-rules contract for the share capital stored there. Any capital band is the one listed in the table above, not an example in the source code.

Directors are appointed and removed by **[the organ the PGR and these articles name]**. The on-chain director flag is the technical permission to convene and to publish. It does not by itself prove a commercial-register filing.

## Information

The board publishes the hashes of **[annual report / other named documents]** through the information contract, with the deadlines these articles set. A shareholder may file an information request there. The response period is the stored response window, once counsel has replaced the placeholder. The document itself stays off-chain. Where it is confidential, the company stores ciphertext and the hash of that ciphertext.

## Shares and the shareholder agreement

Transfer restrictions, the whitelist, lock-ups, pre-emption, tag-along, and drag-along are enforced by the share token together with the share-terms and acquisition contracts, on the terms of the shareholder agreement whose current hash and version are stored in the share-terms contract.

The shareholder agreement is **[dated / version]**. Its keccak256 is **[hash]**, stored as SHA version **[n]**.

A person who is not on the whitelist, or who has not accepted the current SHA version on-chain, cannot receive shares while the transfer policy is set. Counsel decides whether acceptance on-chain is enough, or whether a deed is still required. For a GmbH, counsel decides whether an ERC-20 transfer can transfer the membership interest at all.

## Recovery

A forced transfer is allowed only through the recovery contract: one source, one recipient, one amount, a hash of a board resolution or of a court order, and the stored delay. It is not a general power to move shares. The holder can stop a board-resolution recovery during the delay. A court-order recovery can be stopped during the delay by the board or by the timelock, not by the affected holder alone. Counsel confirms whether that split is acceptable, and what document the hash must commit to.

## Amendment

Changing a contract address in this article, or pointing the share token at a different policy or module, is a **[qualified]** resolution. The timelock is the only address that can set the share token's transfer policy and share modules.
