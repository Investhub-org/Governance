# Lifecycle deadlines

**Not legal advice.** This planner is unaudited software. It does not state Liechtenstein law. The day counts live in [`lifecycle/deadlines/statutory-defaults.ts`](../lifecycle/deadlines/statutory-defaults.ts), and that file says **defaults to verify with Liechtenstein counsel**. They were taken from the unofficial English translation of the Personen- und Gesellschaftsrecht (PGR), LR 216.0, translation date 25 October 2023. The German text on gesetze.li is the text that counts. Nothing here signs, sends, or takes a payment.

The function is `governance.plan_lifecycle_event`. It is a free read. A multi-issuer calendar would be `governance.plan_lifecycle_calendar`, tier `x402`. That call is not implemented. This module does not price it. Where a paid company-law workflow is offered, it is via a licensed partner (in review).

## Run

Node 22. No install, no network.

```bash
node --experimental-strip-types --test lifecycle/deadlines/test/deadlines.test.ts
```

```js
import { planLifecycleEvent } from "./lifecycle/deadlines/index.ts";

planLifecycleEvent({
  issuerId: "synthetic-issuer-001",
  event: { kind: "agm", at: "2026-07-15T10:00:00+02:00" },
});
```

`issuerId` is an opaque slug. Holder and board values are `0x` plus 40 hex characters. Use synthetic addresses such as `0xA11CE00000000000000000000000000000000001`. The tool rejects `@` and a 32-byte hex string, so an email or a private key cannot sit in the payload. The output is `signed: false`, `transmitted: false`, `channel: "simulated"`.

The zone is `Europe/Vaduz` and cannot be switched. A "day" in a statute is a civil day in that zone, kept at the same local time. `GvGovernor` voting delay and period are unix seconds, because that is how the chain counts. They do not skip weekends.

## What is a statute, what is configurable

Pass the seconds stored in `GvCompanyRules` when you have them. Omitting a field means the articles are silent. It does not mean "use the placeholder the contract deployed."

| Input | Silent value | Source when silent | Hard limit |
| --- | --- | --- | --- |
| `agmNoticeSeconds`, `egmNoticeSeconds` | 7 days, PGR Art. 167(3) | statute | Shorter is refused unless `counselPermitsShorterConveningNotice` is true. That flag records a counsel decision. It is not a legal opinion. |
| same fields, `eeaListed: true` | 30 days, PGR Art. 339a(1) | statute | Minimum. The counsel flag does not lower it. |
| EGM, `eeaListed` and `electronicVotingOpen` | 21 days, PGR Art. 339a(3) | statute | Minimum. The flag stands for the prior two-thirds resolution and electronic voting for every shareholder. |
| `informationLeadSeconds` on an AGM | 20 days, PGR Art. 336(1) | statute | Minimum. A longer article value is the one used. |
| `informationLeadSeconds` on an EGM | the value you pass | articles | Art. 336(1) is the ordinary meeting. It is not applied. |
| listed website publication | 21 days, PGR Art. 339e(1), or the longer information lead | statute, or articles if longer | The 21 days are a minimum lead. |
| listed ordinary agenda requests | 21 days, PGR Art. 339d(2) | statute | Fixed. Not an article period. |
| listed bearer record date | end of the 12th civil day before the meeting, PGR Art. 339c(1) | statute | `recordLeadSeconds` is a conflict. The instant is 23:59:59 Europe/Vaduz. |
| listed bearer custody confirmation | sixth working day before the meeting, PGR Art. 339c(1) | statute | Working days follow the calendar below. |
| listed registered record | the meeting, PGR Art. 339c(2) | statute | A positive `recordLeadSeconds` is a conflict. |
| unlisted record | the meeting, PGR Art. 328(2) | statute | The translation states no earlier record date. An article lead is allowed. This is not the governor vote snapshot. |
| `minutesPublicationSeconds`, listed | 7 days, PGR Art. 340a(3) | statute | Maximum. A later article value is refused. An earlier one is used. |
| minutes, not listed, omitted | no day count, PGR Art. 171(4) | statute | Whether Art. 171(4) applies to an AG is open. |
| `responseWindowSeconds` | 30 days | articles | Software placeholder, the same number as `GvCompanyRules.PLACEHOLDER_RESPONSE_WINDOW`. PGR Art. 337 states no day count in the translation. Shorter is allowed. |
| `preEmptionWindowSeconds` | 14 days, PGR Art. 303(2) | statute | Minimum. The counsel flag does not lower it. A longer value is the article period. `GvShareTerms` will still use `block.timestamp + preEmptionWindow` seconds and will not move a weekend. |
| `dividendRecordLeadSeconds` | 0 | articles | No PGR record-date offset was found in Art. 307, Art. 312, or Art. 338(2)(2). |
| `dividendClaimWindowSeconds` | 180 days | articles | Software placeholder. It matches the lifecycle simulation's `GvDividend` deadline. It is not a statute. Pass the timestamp as `deadline`. |
| `sha.dragResponseSeconds`, `sha.tagResponseSeconds` | 14 days | sha | No PGR period was found. `GvAcquisition` takes the close as a `deadline` argument. A shorter SHA value is allowed. |
| `votingWindowSeconds` | 0, vote at the meeting, PGR Art. 334(3) | statute | A positive value is an article window. |
| `votingDelaySeconds` and `votingPeriodSeconds` | unset | articles | Both, or neither. Unix seconds from the meeting, treated as the propose time. `GvGovernor` parameters. Not a PGR period. |

A configured period longer than the statutory default is the one the plan uses (`appliedBecause: "longer_than_default"`, `source: "articles"` or `"sha"`, `comparedWith` set to the PGR article). A configured period shorter than a statutory minimum returns `ok: false`, code `below_statutory_minimum` or `above_statutory_maximum`, and an empty deadline list. The contracts' own `MAX_PERIOD` of 366 days is a software bound.

`GvCompanyRules` deploys an AGM notice placeholder of 14 days and an EGM placeholder of 7 days. Fourteen is longer than Art. 167(3)'s one week, so passing `agmNoticeSeconds: 1209600` uses 14 days. Leaving the field out uses 7.

Section labels default to the draft headings (`articles §meetings`, `articles §information`, `articles §parameters`, `articles §dividend`, `articles §governor`, `shareholder agreement §drag-along`, `shareholder agreement §tag-along`). They are labels, not numbered articles. Pass `articles §12` when counsel has a number.

An ordinary meeting after six calendar months from `financialYearEnd` is `outside_statutory_outer_bound` (PGR Art. 339(1), and Art. 179a for the draft accounts). The month-length is calendar months in Europe/Vaduz, with the day-of-month clamped. 31 December plus six months is the end of 30 June.

## Calendar

`calendar.convention` is `notice_earlier_window_later` unless you pass `none`.

- A latest-by instant (notice, documents, minutes, the information response) that falls on a Saturday, Sunday, or holiday moves to the previous business day. Minutes and the response are not moved to before the meeting.
- A window end the operator still chooses (dividend claim, drag response, tag response, a multi-day vote, agenda requests) moves to the next business day.
- The meeting or the offer instant you supplied does not move. A non-business anchor is a warning.
- The pre-emption close does not move. `GvShareTerms` will not move it either. The plan warns `window_ends_on_non_business_day`.

`useLiechtensteinPreset` defaults to true. The preset is Neujahr, Heilige Drei Könige, Maria Lichtmess, Josefstag, Karfreitag, Ostermontag, Tag der Arbeit, Auffahrt, Pfingstmontag, Fronleichnam, Staatsfeiertag (15 August), Maria Geburt, Allerheiligen, Maria Empfängnis, Weihnachten, and Stefanstag. 2 January is not in the preset. Add or replace dates with `calendar.holidays` (`YYYY-MM-DD`). The preset is a default to verify, not an official calendar.

## Tool shape

The document is [`lifecycle/deadlines/schema.json`](../lifecycle/deadlines/schema.json). `inputSchema` and `outputSchema` are JSON Schema. `planLifecycleEvent` checks the input against `inputSchema`.

`otherEvents` is other events of **this** issuer, used to report overlaps. Overlap is the closed interval from the earliest deadline to the latest. Touching at an endpoint counts. More than one issuer is the unimplemented `x402` tool: the schema rejects an `issuers` field.

Kinds match the lifecycle phases already used with these contracts: `agm`, `egm`, `dividend`, `capital_increase` (the pre-emption window on `GvShareTerms`), `drag_along`, `tag_along`. `onChain.contract` and `onChain.parameter` name the kit function a person would call with the planned instant: `GvAssembly` `noticeDeadline` and `openMeeting`, `GvInformation` `schedulePublication` and `responseWindow`, `GvShare` `balanceOf`, `GvGovernor` `votingDelay`, `votingPeriod`, and `castVote`, `GvDividend` `deadline`, `GvShareTerms` `preEmptionWindow`, `GvAcquisition` `postDrag`, `openTagSale`, and `deadline`. The planner does not read chain state and does not import those contracts.

Audiences are `all_holders_at_record_date`, `affected_class` (only when `classId` is set), and `board`. `latestSendAt` is the deadline instant after any business-day move. A notice sent before the record date is `recipientTiming: "register_not_yet_fixed"`. Supplied holders are a caller snapshot, not a register the tool queried.

Template keys look like `agm.notice`, `agm.information`, `dividend.claim_close`, `preemption.close`, `drag.notice`, `tag.response_close`.

A silent AGM at 15 July 2026 10:00 Europe/Vaduz, with the calendar convention turned off so the civil arithmetic is visible:

| Deadline | Instant | Basis |
| --- | --- | --- |
| `information_available` | 2026-06-25T10:00:00+02:00 | PGR Art. 336(1), statute |
| `notice_dispatch` | 2026-07-08T10:00:00+02:00 | PGR Art. 167(3), statute |
| `record_date`, vote, meeting, minutes | 2026-07-15T10:00:00+02:00 | Art. 328(2), Art. 334(3), Art. 339(1), Art. 171(4) |
| `information_response_close` | 2026-08-14T10:00:00+02:00 | articles §information, 30-day placeholder |

That plan warns `notice_after_information_availability`: the one-week notice is later than the twenty-day report. They are separate duties in the translation. A 21-day article notice removes the warning, because the longer period wins.

A pre-emption window of 864000 seconds (10 days) is refused:

```json
{
  "code": "below_statutory_minimum",
  "field": "articles.preEmptionWindowSeconds",
  "basis": "PGR Art. 303(2)",
  "articleSeconds": 864000,
  "statutorySeconds": 1209600
}
```

## Open questions for Liechtenstein counsel

1. Confirm every citation and day count against the German PGR in force on the day of use (LR 216.0). The constants follow the unofficial English translation dated 25 October 2023.
2. Art. 167(3) says the one-week notice applies unless the articles provide otherwise. This engine refuses a shorter private-company notice unless `counselPermitsShorterConveningNotice` is set. Is a shorter article notice effective?
3. Do Art. 339a to Art. 339e (30 or 21 days, the 12th-day record date, the sixth working day, the website) apply only to a public limited company listed in the EEA? What does "listed in the EEA" require, and does a tokenised private AG ever enter that class?
4. Does Art. 171(4) (minutes available during business hours, no day count) apply to an AG, or do Art. 338 and following displace it, with Art. 340a (seven days) only for an EEA-listed company?
5. Art. 336(1) is twenty days before the ordinary meeting. Is there a document period for an EGM? Do the Auskunftspflichten (Art. 337, and Art. 339d(4) for a listed company) add a response period the translation does not number? The 30-day figure is `GvCompanyRules`'s placeholder.
6. Is "the end of the 12th day before" the meeting day as day 0, and is the end of that day 23:59:59 or 24:00:00?
7. Art. 303(2)'s fourteen days are applied as fourteen civil days from the offer instant. Are they calendar days, and does the publication day count? Across a DST change, fourteen civil days and `14 days` of unix seconds land an hour apart. `GvShareTerms` uses the unix count.
8. Moving a latest-by instant off a weekend or holiday to the previous business day, and a chosen window-end to the next, is a convention of this module. It is not a citation. Which computation-of-time rule actually applies?
9. Is the holiday preset, including 2 February and 19 March and the Easter feasts, the official list for the year in question? 2 January is omitted on purpose.
10. No dividend record date or claim window was found in Art. 307, Art. 311, Art. 312, or Art. 338(2)(2). The 180-day claim default is the lifecycle simulation's `GvDividend` argument, not a statute. What should the articles say?
11. No PGR period was found for drag-along or tag-along. The 14-day SHA default is a placeholder. Does a forced drag also need a consent, a squeeze-out, or a general-meeting resolution?
12. Is six calendar months, day-of-month clamped, the right reading of "within six months" in Art. 339(1) and Art. 179a?
13. The governor ballot is not the meeting vote in Art. 334. Art. 332a postal voting is written for EEA-listed companies. Can a private AG open a multi-day on-chain vote and still have held a general meeting? This plan treats the meeting instant as the propose time.
14. A notice that the one-week default would send after the Art. 336 document date is warned about and not reordered. Should the articles require the notice to be at least as long as the document lead?
