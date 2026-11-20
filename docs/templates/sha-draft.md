# Draft shareholder-agreement clauses

**DRAFT. Not legal advice. Requires review by a Liechtenstein lawyer.**

This is an English clause list for the shareholder agreement (SHA) of **[company, AG or GmbH]**. Counsel rewrites it in the form and language the parties and Liechtenstein law require. The software placeholders in the contracts are not the commercial terms.

## The binding text

The SHA is the document with keccak256 **[hash]**. The company publishes that hash on the share-terms contract at **[GvShareTerms address]**. The published version number is the SHA version.

A later text is a new version only when its hash is published. Holders who want to receive further shares accept the current version by calling `acceptSha` on that contract. While the share token's transfer policy points at the share-terms contract, the token rejects a mint or a transfer to an address that has not accepted the current version or is not on the whitelist.

The parties agree that **[on-chain acceptance is / is not]** enough to bind a transferee, and that **[a deed / a board approval / nothing further]** is also required. Counsel fills this in. For a GmbH interest, counsel states any form the PGR still requires. This draft does not waive it.

The company's articles at **[articles version]** name this contract and this hash. If the articles and this SHA disagree, **[the articles / the SHA / the following rule]** prevail. Counsel fills this in.

## Whitelist and lock-ups

The company may refuse a transfer to an address that is not whitelisted, and may record a lock-up until a timestamp, where this SHA or a subscription document says that holder is locked. The whitelist is not a power to seize shares.

Locked shares cannot be offered in pre-emption or in a tag-along sale. **[They can / they cannot]** be moved by a completed drag-along. The contracts currently allow a drag-along to move locked shares. If the SHA says they cannot, the code has to be changed before deployment. Do not sign a clause the code contradicts.

## Pre-emption

A transfer that is not a tag-along sale and not a drag-along is offered to existing holders for the pre-emption window stored in the company-rules contract, at the price per token unit stated in the offer.

Each other holder may take up to `offered amount * their balance / (supply - seller's balance at the start)`. The original buyer does not exercise that cap. After the window, the buyer may take the remainder at the same price, or the seller may take the unsold shares back. Integer division can leave a single unit in the remainder. The parties accept that rounding.

A sale of a fraction of the supply at or above the tag-along threshold does not use this clause. It uses the tag-along clause.

## Tag-along

If a holder sells a stake at or above the tag-along threshold stored in the company-rules contract, the sale settles only through the acquisition contract, and only after the offer has been open until its deadline.

The offer is the same price per token unit. Each other holder may sell up to the same fraction of their own holding that the seller is selling of the seller's holding. Joining is optional. If nobody joins, the seller's stake can still settle after the deadline.

"Same fraction of each holding" is the rule the contract implements. If the parties want a right to sell their entire holding, counsel changes this clause and the code before deployment.

## Drag-along

A buyer may post an offer on the acquisition contract by escrowing the consideration token for the price times the entire supply. The price is the same for every share. The quorum is at least the drag-along quorum stored in the company-rules contract. The placeholder in the software is 75 percent. The figure in this SHA is **[ ] percent**, and the company stores that figure before anyone relies on the contract.

If holders escrow at least that quorum of the supply before the deadline, every holder can be converted at that price. Conversion can be done address by address after execution. A holder who does not accept is still converted. If the quorum is not reached by the deadline, the buyer takes the escrow back and acceptors take their shares back.

The parties acknowledge that a forced conversion may also need a corporate approval, a squeeze-out proceeding, or a governor resolution. **[List the extra conditions, or state that the on-chain quorum is the agreed condition.]** The contract does not check those extra conditions.

## Recovery

If a holder loses the key to an address, or a competent body orders a transfer, the board may propose one transfer on the recovery contract. The proposal includes the keccak256 of the board minutes or of the court order. The document stays off-chain. The contract does not open the document.

The transfer cannot be executed before the recovery delay stored in the company-rules contract. The software refuses a delay below its floor. The delay in this SHA is **[ ]**.

The affected holder may cancel a board-resolution proposal during the delay. The holder may not cancel a proposal marked as a court order. The board and the timelock may cancel either kind before execution. The parties agree that this is **[acceptable / to be changed as follows]**.

A recovery is not a general power of attorney over the token. There is no function that lets the board choose an arbitrary transfer outside this clause.

## Consideration

Prices in pre-emption, tag-along, and drag-along are amounts of **[consideration token, for example a named stablecoin]** per token unit of the Share Token, in that token's smallest unit. The share-terms contract stores the consideration token address **[address]**.

## No platform party

The parties are the shareholders and the company. No user-interface operator is a party, holds a key, or receives a fee under this SHA. The contracts can be called without that operator.
