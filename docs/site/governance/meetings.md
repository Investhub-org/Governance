# Meetings

A general meeting in this kit is two contracts. `GvAssembly` is the record: AGM or EGM, who convened it, the notice deadline, the agenda, and the hash of the invitation. `GvGovernor` is the ballot. The assembly does not hold tokens and does not count the vote. Shareholders vote on the governor.

InvestHub does not sign, does not hold a role, and does not need to be online. The steps below are reads and transactions on the issuer's contracts. They are not investment advice. The notice periods and the convening fraction start as placeholders on `GvCompanyRules`. Use the numbers counsel stored, not the software defaults. See [Modules](./modules).

The contracts are unaudited.

## Convene

The issuer, or the timelock after ownership moves, appoints directors with `setDirector` on the assembly.

A director convenes with `conveneByBoard` when the board meets the stored minimum. The call carries the meeting type (`AGM` or `EGM`), the invitation hash, an optional content id, and an agenda of at most 16 items. Each item has a title, a document hash, and a resolution class (ordinary or qualified).

A shareholder whose voting power at the previous second meets the stored fraction of past total supply can convene with `conveneByShareholders`. Undelegated shares weigh zero. A transfer or a flash loan in the current second is not counted.

A holder below that fraction files `fileConveningRequest`. Other holders call `supportConveningRequest`. Support is each supporter's votes at the second before the request, added once. `conveneFromRequest` opens the meeting once the stored fraction is met and the request has not expired.

`InvitationNotice` is the event an off-chain notifier can subscribe to. It carries the meeting id, the type, the notice deadline, the invitation hash, and an optional content id. It carries no email address and no member list. The notifier reads holders from the share token and addresses from the company's own register, which stays off-chain.

Anyone can call `openMeeting` after the notice deadline stored on that meeting. A later change to the rules does not shorten a notice that was already given. The convener or a director closes or cancels it.

## Vote

Votes start at zero until a holder calls `delegate` on the share, usually to themselves. The governor reads the proposer's votes at `clock() - 1`, so a delegation in the current second is visible on the next second.

Binding a governor proposal to an agenda item records the resolution class. Execution uses the strictest class bound to that proposal. An unbound proposal is checked as qualified. A binding cannot lower the class.

`propose`, `castVote`, `queue`, and `execute` are the OpenZeppelin governor calls. For must be strictly greater than Against. Quorum counts For and Abstain. When the governor's binding mode is Articles or Both, `execute` calls `GvAssembly.assertExecutable` before the timelock runs. If the articles outcome is not `passed`, the timelock does not run. Governor mode does not add that check. `state()` can still read Succeeded or Queued in that case: the refusal is inside execution.

Queue and execute wait out the timelock delay. The executor is the governor contract. There is no open executor role and no InvestHub signer.

## What you can read without an account

- `IssuerKitDeployed` and `IssuerSetDeployed` on the factory, and `deploymentByGovernor`.
- The assembly meeting: type, phase, notice deadline, agenda, invitation hash.
- `governor.state`, `proposalVotes`, `quorum`, `votingDelay`, `votingPeriod`.
- `governor.timelock()`.

No InvestHub API is required for those reads. A directory entry, if one exists, is a separate pointer. Compare it with the factory event before trusting it.
