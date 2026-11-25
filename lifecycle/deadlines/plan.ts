import { createHash } from "node:crypto";

import {
  adjacentBusiness,
  civilFromUtc,
  endOfCivilDay,
  formatInstant,
  holidaySet,
  isBusinessInstant,
  shiftByPeriod,
  workingDaysBefore,
  zonedToUtc,
  addMonths,
} from "./calendar.ts";
import type { CalendarState } from "./calendar.ts";
import { resolvePeriod } from "./resolve-period.ts";
import type { PeriodRequest } from "./resolve-period.ts";
import {
  DEFAULT_TIME_ZONE,
  DISCLAIMER,
  PLACEHOLDER_DIVIDEND_CLAIM_SECONDS,
  PLACEHOLDER_DRAG_RESPONSE_SECONDS,
  PLACEHOLDER_RESPONSE_WINDOW_SECONDS,
  PLACEHOLDER_TAG_RESPONSE_SECONDS,
  PREMIUM_NOTE,
  SECONDS_PER_DAY,
  STATUTE_AGM_INFORMATION_LEAD_SECONDS,
  STATUTE_AGM_OUTER_MONTHS,
  STATUTE_CONVENING_NOTICE_SECONDS,
  STATUTE_LISTED_AGENDA_REQUEST_SECONDS,
  STATUTE_LISTED_BEARER_CUSTODY_WORKING_DAYS,
  STATUTE_LISTED_BEARER_RECORD_DAYS,
  STATUTE_LISTED_NOTICE_SECONDS,
  STATUTE_LISTED_OTHER_NOTICE_SECONDS,
  STATUTE_LISTED_RESULTS_SECONDS,
  STATUTE_LISTED_WEBSITE_LEAD_SECONDS,
  STATUTE_PREEMPTION_SECONDS,
  TOOL_NAME,
} from "./statutory-defaults.ts";
import type {
  Audience,
  BusinessDayAdjustment,
  Clock,
  Deadline,
  EventKind,
  LegalBasis,
  NormalizedEvent,
  NormalizedInput,
  OnChainHint,
  Overlap,
  PlanError,
  PlanInput,
  PlanResult,
  PlanWarning,
  PremiumMarker,
  Shift,
  SimulatedNotification,
  Source,
} from "./types.ts";
import { validateInput } from "./validate.ts";

const COUNSEL = "Not legal advice. defaults to verify with Liechtenstein counsel.";

const PREMIUM: PremiumMarker = {
  name: "governance.plan_lifecycle_calendar",
  tier: "x402",
  implemented: false,
  note: PREMIUM_NOTE,
};

interface Draft {
  id: string;
  kind: EventKind;
  utcMs: number;
  action: string;
  audiences: Audience[];
  basis: LegalBasis;
  shift: Shift;
  clock: Clock;
  onChain: OnChainHint | null;
  rank: number;
  /** latest_by will not move earlier than this instant. */
  notBeforeMs?: number;
  warnCode?: PlanWarning["code"];
}

interface Built {
  drafts: Draft[];
  errors: PlanError[];
  warnings: PlanWarning[];
}

export function planLifecycleEvent(input: unknown): PlanResult {
  const planId = sha256(canonical(input));
  const issuerId = publicIssuer(input);
  const validated = validateInput(input);
  if ("errors" in validated) return failure(planId, issuerId, validated.errors);

  const norm = validated.value;
  const cal = calendarFor(norm);
  const primary = planOne(norm, norm.event, cal);
  const others = norm.otherEvents.map((event) => ({ event, built: planOne(norm, event, cal) }));
  const errors = dedupe([...primary.errors, ...others.flatMap((item) => item.built.errors)]);
  if (errors.length > 0) return failure(sha256(canonical(norm)), norm.issuerId, errors);

  const compiled = compile(primary.drafts, cal, norm.asOfMs);
  if ("error" in compiled) return failure(sha256(canonical(norm)), norm.issuerId, [compiled.error]);

  const warnings = dedupeWarnings([
    ...primary.warnings,
    ...compiled.warnings,
    ...noticeOrderWarning(compiled.deadlines),
    ...affectedWarning(compiled.deadlines, norm),
  ]);

  const spans: Array<{ id: string; kind: EventKind; min: number; max: number }> = [
    span(norm.event, compiled.deadlines),
  ];
  for (const item of others) {
    const other = compile(item.built.drafts, cal, norm.asOfMs);
    if ("error" in other) return failure(sha256(canonical(norm)), norm.issuerId, [other.error]);
    spans.push(span(item.event, other.deadlines));
  }

  const deadlines = compiled.deadlines;
  return {
    ok: true,
    tool: TOOL_NAME,
    tier: "free",
    signed: false,
    transmitted: false,
    disclaimer: DISCLAIMER,
    issuerId: norm.issuerId,
    eventId: norm.event.id,
    timeZone: DEFAULT_TIME_ZONE,
    deadlines,
    notifications: notificationsFor(deadlines, norm),
    errors: [],
    warnings,
    overlaps: overlapsOf(spans, cal.timeZone),
    premium: PREMIUM,
    planId: sha256(canonical(norm)),
  };
}

function planOne(norm: NormalizedInput, event: NormalizedEvent, cal: CalendarState): Built {
  const built = dispatch(norm, event, cal);
  if (!isBusinessInstant(event.atMs, cal)) {
    built.warnings.push({
      code: "anchor_not_business_day",
      message: `${event.id} is not a business day in ${DEFAULT_TIME_ZONE}. The supplied instant was not moved.`,
    });
  }
  if (event.kind === "drag_along" || event.kind === "tag_along") {
    built.warnings.push({
      code: "sha_window_not_a_statute",
      message:
        "Drag-along and tag-along windows are shareholder-agreement periods. No PGR day count was applied. " + COUNSEL,
    });
  }
  for (const draft of built.drafts) {
    if (draft.basis.appliedBecause === "counsel_permits_shorter") {
      built.warnings.push({
        code: "shorter_than_published_statutory_default",
        message: `${draft.id} uses a period shorter than ${draft.basis.comparedWith ?? "the published default"} because counselPermitsShorterConveningNotice is set.`,
      });
    }
  }
  return built;
}

function dispatch(norm: NormalizedInput, event: NormalizedEvent, cal: CalendarState): Built {
  const timeZone = cal.timeZone;
  switch (event.kind) {
    case "agm":
    case "egm":
      return planMeeting(norm, event, timeZone, cal);
    case "dividend":
      return planDividend(norm, event, timeZone);
    case "capital_increase":
      return planPreEmption(norm, event, timeZone);
    case "drag_along":
      return planAcquisition(norm, event, timeZone, "drag");
    case "tag_along":
      return planAcquisition(norm, event, timeZone, "tag");
    default:
      return { drafts: [], errors: [], warnings: [] };
  }
}

function planMeeting(norm: NormalizedInput, event: NormalizedEvent, timeZone: string, cal: CalendarState): Built {
  const errors: PlanError[] = [];
  const drafts: Draft[] = [];
  const { articles, labels } = norm;
  const kind = event.kind === "egm" ? "egm" : "agm";
  outerBound(event, timeZone, errors);

  const notice = resolvePeriod(noticeRequest(kind, articles, labels));
  if ("error" in notice) errors.push(notice.error);
  else {
    const at = shiftByPeriod(event.atMs, -notice.basis.appliedSeconds, timeZone);
    drafts.push(
      row({
        id: "notice_dispatch",
        utcMs: at,
        action: "Dispatch the invitation with the agenda. This is the latest send.",
        audiences: ["all_holders_at_record_date", "board"],
        basis: notice.basis,
        shift: "latest_by",
        onChain: { contract: "GvAssembly", parameter: "noticeDeadline" },
        rank: 40,
      }, kind),
    );
    if (event.classId) {
      drafts.push(
        row({
          id: "class_notice_dispatch",
          utcMs: at,
          action: `Dispatch the class notice for ${event.classId}. Counsel confirms the resolution affects that class unequally.`,
          audiences: ["affected_class", "board"],
          basis: fixedBasis(
            "PGR Art. 173(2)",
            "statute",
            notice.basis.appliedSeconds,
            "Class notice uses the same length as the general-meeting notice.",
            notice.basis.ref,
          ),
          shift: "latest_by",
          onChain: { contract: "GvAssembly", parameter: "noticeDeadline" },
          rank: 41,
        }, kind),
      );
    }
  }

  if (kind === "agm") {
    const info = resolvePeriod({
      field: "articles.informationLeadSeconds",
      configured: articles.informationLeadSeconds,
      defaultSeconds: STATUTE_AGM_INFORMATION_LEAD_SECONDS,
      minimumSeconds: STATUTE_AGM_INFORMATION_LEAD_SECONDS,
      defaultSource: "statute",
      defaultRef: "PGR Art. 336(1)",
      configuredSource: "articles",
      configuredRef: labels.informationSection,
      comparedWith: "PGR Art. 336(1)",
    });
    if ("error" in info) errors.push(info.error);
    else {
      drafts.push(
        row({
          id: "information_available",
          utcMs: shiftByPeriod(event.atMs, -info.basis.appliedSeconds, timeZone),
          action: "Make the business report and the audit report available for inspection.",
          audiences: ["all_holders_at_record_date", "board"],
          basis: info.basis,
          shift: "latest_by",
          onChain: { contract: "GvInformation", parameter: "schedulePublication" },
          rank: 10,
        }, kind),
      );
      if (articles.eeaListed) pushWebsite(drafts, kind, event, timeZone, info.basis.appliedSeconds, labels.informationSection);
    }
  } else if (articles.informationLeadSeconds !== undefined) {
    const info = resolvePeriod({
      field: "articles.informationLeadSeconds",
      configured: articles.informationLeadSeconds,
      defaultSeconds: articles.informationLeadSeconds,
      defaultSource: "articles",
      defaultRef: labels.informationSection,
      configuredSource: "articles",
      configuredRef: labels.informationSection,
      comparedWith: "PGR Art. 336(1) applies to the ordinary meeting; it is not applied to this EGM",
    });
    if ("error" in info) errors.push(info.error);
    else {
      drafts.push(
        row({
          id: "information_available",
          utcMs: shiftByPeriod(event.atMs, -info.basis.appliedSeconds, timeZone),
          action: "Make the EGM documents named in the articles available.",
          audiences: ["all_holders_at_record_date", "board"],
          basis: info.basis,
          shift: "latest_by",
          onChain: { contract: "GvInformation", parameter: "schedulePublication" },
          rank: 10,
        }, kind),
      );
    }
  }

  if (articles.eeaListed && kind === "egm") {
    pushWebsite(drafts, kind, event, timeZone, articles.informationLeadSeconds ?? STATUTE_LISTED_WEBSITE_LEAD_SECONDS, labels.informationSection);
  }

  if (articles.eeaListed && kind === "agm") {
    drafts.push(
      row({
        id: "agenda_request_close",
        utcMs: shiftByPeriod(event.atMs, -STATUTE_LISTED_AGENDA_REQUEST_SECONDS, timeZone),
        action: "Last instant for a 5% holder request to put an item on the ordinary agenda.",
        audiences: ["all_holders_at_record_date", "board"],
        basis: fixedBasis(
          "PGR Art. 339d(2)",
          "statute",
          STATUTE_LISTED_AGENDA_REQUEST_SECONDS,
          "Requests must be received at the latest 21 days before the ordinary general meeting.",
        ),
        shift: "window_end",
        onChain: null,
        rank: 30,
      }, kind),
    );
  }

  if (articles.eeaListed && articles.shareForm === "bearer") {
    if (articles.recordLeadSeconds !== undefined) {
      errors.push({
        code: "conflicts_with_statute",
        field: "articles.recordLeadSeconds",
        basis: "PGR Art. 339c(1)",
        articleSeconds: articles.recordLeadSeconds,
        statutorySeconds: STATUTE_LISTED_BEARER_RECORD_DAYS * SECONDS_PER_DAY,
        message: "A listed bearer record date is the end of the 12th day before the meeting. An article lead cannot replace it.",
      });
    } else {
      const day = endOfCivilDay(shiftByPeriod(event.atMs, -STATUTE_LISTED_BEARER_RECORD_DAYS * SECONDS_PER_DAY, timeZone), timeZone);
      drafts.push(
        row({
          id: "record_date",
          utcMs: day,
          action: "Bearer record date. Holdings are taken at the end of this civil day. This is not the governor vote snapshot.",
          audiences: ["all_holders_at_record_date", "board"],
          basis: fixedBasis(
            "PGR Art. 339c(1)",
            "statute",
            STATUTE_LISTED_BEARER_RECORD_DAYS * SECONDS_PER_DAY,
            "End of the 12th civil day before the meeting (23:59:59 Europe/Vaduz). The meeting day is day 0.",
          ),
          shift: "fixed",
          warnCode: "fixed_date_not_business_day",
          onChain: { contract: "GvShare", parameter: "balanceOf" },
          rank: 60,
        }, kind),
      );
    }
    drafts.push(
      row({
        id: "custody_confirmation",
        utcMs: 0,
        action: "Last instant for the custody confirmation of bearer holdings on the record date.",
        audiences: ["all_holders_at_record_date", "board"],
        basis: fixedBasis(
          "PGR Art. 339c(1)",
          "statute",
          STATUTE_LISTED_BEARER_CUSTODY_WORKING_DAYS * SECONDS_PER_DAY,
          "No later than the end of the sixth working day before the meeting. The meeting day is not counted.",
        ),
        shift: "fixed",
        onChain: null,
        rank: 50,
      }, kind),
    );
  } else if (articles.eeaListed && articles.recordLeadSeconds !== undefined && articles.recordLeadSeconds > 0) {
    errors.push({
      code: "conflicts_with_statute",
      field: "articles.recordLeadSeconds",
      basis: "PGR Art. 339c(2)",
      articleSeconds: articles.recordLeadSeconds,
      message: "For listed registered shares the translation treats the share-register entry on the meeting day as sufficient.",
    });
  } else {
    const lead = articles.recordLeadSeconds ?? 0;
    const leadResult = resolvePeriod({
      field: "articles.recordLeadSeconds",
      configured: articles.recordLeadSeconds,
      defaultSeconds: 0,
      allowZero: true,
      defaultSource: articles.eeaListed ? "statute" : "statute",
      defaultRef: articles.eeaListed ? "PGR Art. 339c(2)" : "PGR Art. 328(2)",
      configuredSource: "articles",
      configuredRef: labels.noticeSection,
      comparedWith: articles.eeaListed
        ? "PGR Art. 339c(2)"
        : "PGR Art. 328(2) (no record-date offset in the 25 October 2023 translation)",
    });
    if ("error" in leadResult) errors.push(leadResult.error);
    else {
      drafts.push(
        row({
          id: "record_date",
          utcMs: shiftByPeriod(event.atMs, -lead, timeZone),
          action: articles.eeaListed
            ? "Registered record date, the meeting day. This is not the governor vote snapshot."
            : "Register used for this meeting. The translation states no record-date offset for a company that is not listed. This is not the governor vote snapshot.",
          audiences: ["all_holders_at_record_date", "board"],
          basis: lead === 0 && articles.recordLeadSeconds === undefined
            ? fixedBasis(
                articles.eeaListed ? "PGR Art. 339c(2)" : "PGR Art. 328(2)",
                "statute",
                0,
                articles.eeaListed
                  ? "Evidence in the name of the person entered in the share register on the meeting day."
                  : "The translation ties shareholder status against the company to the share register and states no earlier record date.",
              )
            : leadResult.basis,
          shift: "fixed",
          warnCode: "fixed_date_not_business_day",
          onChain: { contract: "GvShare", parameter: "balanceOf" },
          rank: 60,
        }, kind),
      );
    }
  }

  const governor = governorVote(articles, labels, errors);
  if (governor === "chain") {
    const open = event.atMs + (articles.votingDelaySeconds ?? 0) * 1000;
    const close = open + (articles.votingPeriodSeconds ?? 0) * 1000;
    drafts.push(
      row({
        id: "voting_open",
        utcMs: open,
        action: "On-chain ballot opens. Counted in unix seconds from the meeting instant, which this plan treats as the propose time.",
        audiences: ["all_holders_at_record_date"],
        basis: chainVoteBasis(labels.governorSection, articles.votingDelaySeconds ?? 0),
        shift: "unix",
        clock: "unix",
        onChain: { contract: "GvGovernor", parameter: "votingDelay" },
        rank: 70,
      }, kind),
    );
    drafts.push(
      row({
        id: "voting_close",
        utcMs: close,
        action: "On-chain ballot closes. The chain does not skip weekends.",
        audiences: ["all_holders_at_record_date"],
        basis: chainVoteBasis(labels.governorSection, articles.votingPeriodSeconds ?? 0),
        shift: "unix",
        clock: "unix",
        onChain: { contract: "GvGovernor", parameter: "votingPeriod" },
        rank: 90,
      }, kind),
    );
  } else if (governor === "meeting") {
    const vote = resolvePeriod({
      field: "articles.votingWindowSeconds",
      configured: articles.votingWindowSeconds,
      defaultSeconds: 0,
      allowZero: true,
      defaultSource: "statute",
      defaultRef: "PGR Art. 334(3)",
      configuredSource: "articles",
      configuredRef: labels.governorSection,
      comparedWith: "PGR Art. 334(3) (voting is at the general meeting; Art. 332a postal voting is written for EEA-listed companies)",
    });
    if ("error" in vote) errors.push(vote.error);
    else {
      drafts.push(
        row({
          id: "voting_open",
          utcMs: event.atMs,
          action: "Voting opens.",
          audiences: ["all_holders_at_record_date"],
          basis: vote.basis,
          shift: "anchor",
          onChain: { contract: "GvGovernor", parameter: "castVote" },
          rank: 70,
        }, kind),
      );
      drafts.push(
        row({
          id: "voting_close",
          utcMs: shiftByPeriod(event.atMs, vote.basis.appliedSeconds, timeZone),
          action: "Voting closes.",
          audiences: ["all_holders_at_record_date"],
          basis: vote.basis,
          shift: vote.basis.appliedSeconds > 0 ? "window_end" : "anchor",
          onChain: { contract: "GvGovernor", parameter: "castVote" },
          rank: 90,
        }, kind),
      );
    }
  }

  drafts.push(
    row({
      id: "meeting",
      utcMs: event.atMs,
      action: kind === "agm" ? "Hold the ordinary general meeting." : "Hold the extraordinary general meeting.",
      audiences: ["board", "all_holders_at_record_date"],
      basis: fixedBasis(
        kind === "agm" ? "PGR Art. 339(1)" : "PGR Art. 339(2)",
        "statute",
        0,
        kind === "agm"
          ? "The ordinary meeting is the supplied instant. Art. 338(2) lists the powers, including the dividend declaration."
          : "An extraordinary meeting is convened as needed. The supplied instant was not moved.",
      ),
      shift: "anchor",
      onChain: { contract: "GvAssembly", parameter: "openMeeting" },
      rank: 80,
    }, kind),
  );

  pushMinutes(drafts, errors, kind, event, timeZone, articles, labels.minutesSection);
  pushResponse(drafts, errors, kind, event, timeZone, articles, labels.informationSection);

  const custody = drafts.find((item) => item.id === "custody_confirmation");
  if (custody) {
    const at = workingDaysBefore(event.atMs, STATUTE_LISTED_BEARER_CUSTODY_WORKING_DAYS, cal);
    custody.utcMs = at ?? 0;
    if (at === null) {
      errors.push({
        code: "no_business_day",
        field: "calendar.holidays",
        message: "No sixth working day was found before the meeting.",
      });
    }
  }

  return { drafts, errors, warnings: [] };
}

function planDividend(norm: NormalizedInput, event: NormalizedEvent, timeZone: string): Built {
  const errors: PlanError[] = [];
  const drafts: Draft[] = [];
  const lead = resolvePeriod({
    field: "articles.dividendRecordLeadSeconds",
    configured: norm.articles.dividendRecordLeadSeconds,
    defaultSeconds: 0,
    allowZero: true,
    placeholderDefault: norm.articles.dividendRecordLeadSeconds === undefined,
    defaultSource: "articles",
    defaultRef: norm.labels.dividendSection,
    configuredSource: "articles",
    configuredRef: norm.labels.dividendSection,
    comparedWith: "PGR Art. 307, Art. 312, and Art. 338(2)(2) state no record-date offset in the 25 October 2023 translation",
  });
  const claim = resolvePeriod({
    field: "articles.dividendClaimWindowSeconds",
    configured: norm.articles.dividendClaimWindowSeconds,
    defaultSeconds: PLACEHOLDER_DIVIDEND_CLAIM_SECONDS,
    placeholderDefault: norm.articles.dividendClaimWindowSeconds === undefined,
    defaultSource: "articles",
    defaultRef: norm.labels.dividendSection,
    configuredSource: "articles",
    configuredRef: norm.labels.dividendSection,
    comparedWith: "no PGR claim-window day count in the 25 October 2023 translation; 180 days is the lifecycle simulation's GvDividend deadline, not a statute",
  });
  if ("error" in lead) errors.push(lead.error);
  if ("error" in claim) errors.push(claim.error);
  if (!("error" in lead)) {
    drafts.push(
      row({
        id: "dividend_record",
        utcMs: shiftByPeriod(event.atMs, -lead.basis.appliedSeconds, timeZone),
        action: "Dividend record date. Build the merkle leaves from share balances, not from delegated votes.",
        audiences: ["all_holders_at_record_date", "board"],
        basis: lead.basis,
        shift: "fixed",
        warnCode: "fixed_date_not_business_day",
        onChain: { contract: "GvDividend", parameter: "merkleRoot" },
        rank: 60,
      }, "dividend"),
    );
  }
  drafts.push(
    row({
      id: "dividend_claim_open",
      utcMs: event.atMs,
      action: "Dividend claim window opens.",
      audiences: ["all_holders_at_record_date"],
      basis: fixedBasis(
        norm.labels.dividendSection,
        "articles",
        0,
        "The supplied instant is when claims open. PGR Art. 312 does not number a claim window.",
        "PGR Art. 312",
      ),
      shift: "anchor",
      onChain: { contract: "GvDividend", parameter: "claim" },
      rank: 80,
    }, "dividend"),
  );
  if (!("error" in claim)) {
    drafts.push(
      row({
        id: "dividend_claim_close",
        utcMs: shiftByPeriod(event.atMs, claim.basis.appliedSeconds, timeZone),
        action: "Dividend claim window closes. Pass this instant as the GvDividend deadline.",
        audiences: ["all_holders_at_record_date", "board"],
        basis: claim.basis,
        shift: "window_end",
        onChain: { contract: "GvDividend", parameter: "deadline" },
        rank: 100,
      }, "dividend"),
    );
  }
  return { drafts, errors, warnings: [] };
}

function planPreEmption(norm: NormalizedInput, event: NormalizedEvent, timeZone: string): Built {
  const errors: PlanError[] = [];
  const drafts: Draft[] = [];
  const window = resolvePeriod({
    field: "articles.preEmptionWindowSeconds",
    configured: norm.articles.preEmptionWindowSeconds,
    defaultSeconds: STATUTE_PREEMPTION_SECONDS,
    minimumSeconds: STATUTE_PREEMPTION_SECONDS,
    defaultSource: "statute",
    defaultRef: "PGR Art. 303(2)",
    configuredSource: "articles",
    configuredRef: norm.labels.preEmptionSection,
    comparedWith: "PGR Art. 303(2)",
  });
  const audiences: Audience[] = event.classId
    ? ["all_holders_at_record_date", "affected_class", "board"]
    : ["all_holders_at_record_date", "board"];
  drafts.push(
    row({
      id: "preemption_open",
      utcMs: event.atMs,
      action: "Publish the subscription offer. Each shareholder's proportion is PGR Art. 303(1).",
      audiences,
      basis: fixedBasis("PGR Art. 303(2)", "statute", 0, "Publication of the offer. The fourteen-day floor applies to the close, not to this instant."),
      shift: "anchor",
      onChain: { contract: "GvShareTerms", parameter: "startPreEmption" },
      rank: 80,
    }, "capital_increase"),
  );
  if ("error" in window) errors.push(window.error);
  else {
    drafts.push(
      row({
        id: "preemption_close",
        utcMs: shiftByPeriod(event.atMs, window.basis.appliedSeconds, timeZone),
        action:
          "Subscription window closes, counted in civil days. GvShareTerms instead stores block.timestamp plus preEmptionWindow seconds and will not move a weekend. Widen the stored window if the contract must stay open through a later business day.",
        audiences,
        basis: window.basis,
        shift: "fixed",
        warnCode: "window_ends_on_non_business_day",
        onChain: { contract: "GvShareTerms", parameter: "preEmptionWindow" },
        rank: 100,
      }, "capital_increase"),
    );
  }
  return { drafts, errors, warnings: [] };
}

function planAcquisition(
  norm: NormalizedInput,
  event: NormalizedEvent,
  timeZone: string,
  which: "drag" | "tag",
): Built {
  const errors: PlanError[] = [];
  const drafts: Draft[] = [];
  const configured = which === "drag" ? norm.sha.dragResponseSeconds : norm.sha.tagResponseSeconds;
  const section = which === "drag" ? norm.labels.dragSection : norm.labels.tagSection;
  const field = which === "drag" ? "sha.dragResponseSeconds" : "sha.tagResponseSeconds";
  const fallback = which === "drag" ? PLACEHOLDER_DRAG_RESPONSE_SECONDS : PLACEHOLDER_TAG_RESPONSE_SECONDS;
  const window = resolvePeriod({
    field,
    configured,
    defaultSeconds: fallback,
    placeholderDefault: configured === undefined,
    defaultSource: "sha",
    defaultRef: section,
    configuredSource: "sha",
    configuredRef: section,
    comparedWith: "no PGR article located that sets this window",
  });
  const openId = which === "drag" ? "drag_notice" : "tag_notice";
  const closeId = which === "drag" ? "drag_response_close" : "tag_response_close";
  const audiences: Audience[] = event.classId
    ? ["all_holders_at_record_date", "affected_class", "board"]
    : ["all_holders_at_record_date", "board"];
  drafts.push(
    row({
      id: openId,
      utcMs: event.atMs,
      action: which === "drag" ? "Notify holders of the drag-along offer." : "Notify holders of the tag-along offer.",
      audiences,
      basis: fixedBasis(section, "sha", 0, "The offer instant was supplied by the caller. No PGR period was applied.", "no PGR article located that sets this window"),
      shift: "anchor",
      onChain: { contract: "GvAcquisition", parameter: which === "drag" ? "postDrag" : "openTagSale" },
      rank: 80,
    }, which === "drag" ? "drag_along" : "tag_along"),
  );
  if ("error" in window) errors.push(window.error);
  else {
    drafts.push(
      row({
        id: closeId,
        utcMs: shiftByPeriod(event.atMs, window.basis.appliedSeconds, timeZone),
        action:
          which === "drag"
            ? "Drag-along response window closes. Pass this instant as the GvAcquisition deadline."
            : "Tag-along response window closes. Pass this instant as the GvAcquisition deadline.",
        audiences,
        basis: window.basis,
        shift: "window_end",
        onChain: { contract: "GvAcquisition", parameter: "deadline" },
        rank: 100,
      }, which === "drag" ? "drag_along" : "tag_along"),
    );
  }
  return { drafts, errors, warnings: [] };
}

function noticeRequest(
  kind: "agm" | "egm",
  articles: NormalizedInput["articles"],
  labels: NormalizedInput["labels"],
): PeriodRequest {
  const configured = kind === "agm" ? articles.agmNoticeSeconds : articles.egmNoticeSeconds;
  const field = kind === "agm" ? "articles.agmNoticeSeconds" : "articles.egmNoticeSeconds";
  if (articles.eeaListed && !(kind === "egm" && articles.electronicVotingOpen)) {
    return {
      field,
      configured,
      defaultSeconds: STATUTE_LISTED_NOTICE_SECONDS,
      minimumSeconds: STATUTE_LISTED_NOTICE_SECONDS,
      defaultSource: "statute",
      defaultRef: "PGR Art. 339a(1)",
      configuredSource: "articles",
      configuredRef: labels.noticeSection,
      comparedWith: "PGR Art. 339a(1)",
    };
  }
  if (articles.eeaListed && kind === "egm" && articles.electronicVotingOpen) {
    return {
      field,
      configured,
      defaultSeconds: STATUTE_LISTED_OTHER_NOTICE_SECONDS,
      minimumSeconds: STATUTE_LISTED_OTHER_NOTICE_SECONDS,
      defaultSource: "statute",
      defaultRef: "PGR Art. 339a(3)",
      configuredSource: "articles",
      configuredRef: labels.noticeSection,
      comparedWith: "PGR Art. 339a(3)",
    };
  }
  return {
    field,
    configured,
    defaultSeconds: STATUTE_CONVENING_NOTICE_SECONDS,
    displaceableDefault: true,
    counselPermitsShorter: articles.counselPermitsShorterConveningNotice,
    defaultSource: "statute",
    defaultRef: "PGR Art. 167(3)",
    configuredSource: "articles",
    configuredRef: labels.noticeSection,
    comparedWith: "PGR Art. 167(3)",
  };
}

function pushWebsite(
  drafts: Draft[],
  kind: "agm" | "egm",
  event: NormalizedEvent,
  timeZone: string,
  informationSeconds: number,
  section: string,
): void {
  const seconds = Math.max(STATUTE_LISTED_WEBSITE_LEAD_SECONDS, informationSeconds);
  const lengthened = seconds > STATUTE_LISTED_WEBSITE_LEAD_SECONDS;
  drafts.push(
    row({
      id: "website_documents",
      utcMs: shiftByPeriod(event.atMs, -seconds, timeZone),
      action: "Publish the convening notice and the meeting documents on the company website.",
      audiences: ["all_holders_at_record_date"],
      basis: lengthened
        ? {
            source: "articles",
            ref: section,
            comparedWith: "PGR Art. 339e(1)",
            statutoryDefaultSeconds: STATUTE_LISTED_WEBSITE_LEAD_SECONDS,
            configuredSeconds: informationSeconds,
            appliedSeconds: seconds,
            appliedBecause: "longer_than_default",
            placeholder: false,
            note: `The article information lead is longer than 21 days, so the website publication uses the longer lead. ${COUNSEL}`,
          }
        : fixedBasis("PGR Art. 339e(1)", "statute", seconds, "Website information is available from at the latest 21 days before the meeting."),
      shift: "latest_by",
      onChain: null,
      rank: 20,
    }, kind),
  );
}

function pushMinutes(
  drafts: Draft[],
  errors: PlanError[],
  kind: "agm" | "egm",
  event: NormalizedEvent,
  timeZone: string,
  articles: NormalizedInput["articles"],
  section: string,
): void {
  if (articles.eeaListed) {
    const minutes = resolvePeriod({
      field: "articles.minutesPublicationSeconds",
      configured: articles.minutesPublicationSeconds,
      defaultSeconds: STATUTE_LISTED_RESULTS_SECONDS,
      maximumSeconds: STATUTE_LISTED_RESULTS_SECONDS,
      allowZero: true,
      defaultSource: "statute",
      defaultRef: "PGR Art. 340a(3)",
      configuredSource: "articles",
      configuredRef: section,
      comparedWith: "PGR Art. 340a(3)",
    });
    if ("error" in minutes) errors.push(minutes.error);
    else {
      drafts.push(
        row({
          id: "minutes_publication",
          utcMs: shiftByPeriod(event.atMs, minutes.basis.appliedSeconds, timeZone),
          action: "Publish the voting results.",
          audiences: ["all_holders_at_record_date", "board"],
          basis: minutes.basis,
          shift: "latest_by",
          notBeforeMs: event.atMs,
          onChain: { contract: "GvAssembly", parameter: "minutes" },
          rank: 110,
        }, kind),
      );
    }
    return;
  }
  if (articles.minutesPublicationSeconds === undefined) {
    drafts.push(
      row({
        id: "minutes_available",
        utcMs: event.atMs,
        action: "Make the minutes available to persons entitled to vote during business hours. The translation states no day count.",
        audiences: ["all_holders_at_record_date", "board"],
        basis: fixedBasis(
          "PGR Art. 171(4)",
          "statute",
          0,
          "Whether Art. 171(4) applies to an AG beside Art. 338 and following is an open question. No day count was added.",
        ),
        shift: "anchor",
        onChain: { contract: "GvAssembly", parameter: "minutes" },
        rank: 110,
      }, kind),
    );
    return;
  }
  const minutes = resolvePeriod({
    field: "articles.minutesPublicationSeconds",
    configured: articles.minutesPublicationSeconds,
    defaultSeconds: articles.minutesPublicationSeconds,
    allowZero: true,
    defaultSource: "articles",
    defaultRef: section,
    configuredSource: "articles",
    configuredRef: section,
    comparedWith: "PGR Art. 171(4) (no day count in the translation)",
  });
  if ("error" in minutes) errors.push(minutes.error);
  else {
    drafts.push(
      row({
        id: "minutes_publication",
        utcMs: shiftByPeriod(event.atMs, minutes.basis.appliedSeconds, timeZone),
        action: "Publish the minutes within the period the articles set.",
        audiences: ["all_holders_at_record_date", "board"],
        basis: minutes.basis,
        shift: "latest_by",
        notBeforeMs: event.atMs,
        onChain: { contract: "GvAssembly", parameter: "minutes" },
        rank: 110,
      }, kind),
    );
  }
}

function pushResponse(
  drafts: Draft[],
  errors: PlanError[],
  kind: "agm" | "egm",
  event: NormalizedEvent,
  timeZone: string,
  articles: NormalizedInput["articles"],
  section: string,
): void {
  const response = resolvePeriod({
    field: "articles.responseWindowSeconds",
    configured: articles.responseWindowSeconds,
    defaultSeconds: PLACEHOLDER_RESPONSE_WINDOW_SECONDS,
    placeholderDefault: articles.responseWindowSeconds === undefined,
    defaultSource: "articles",
    defaultRef: section,
    configuredSource: "articles",
    configuredRef: section,
    comparedWith: "GvCompanyRules.PLACEHOLDER_RESPONSE_WINDOW; PGR Art. 337 sets no day count in the 25 October 2023 translation",
  });
  if ("error" in response) errors.push(response.error);
  else {
    drafts.push(
      row({
        id: "information_response_close",
        utcMs: shiftByPeriod(event.atMs, response.basis.appliedSeconds, timeZone),
        action: "Last instant for the board to answer an information request filed at the meeting.",
        audiences: ["board", "all_holders_at_record_date"],
        basis: response.basis,
        shift: "latest_by",
        notBeforeMs: event.atMs,
        onChain: { contract: "GvInformation", parameter: "responseWindow" },
        rank: 120,
      }, kind),
    );
  }
}

function outerBound(event: NormalizedEvent, timeZone: string, errors: PlanError[]): void {
  if (event.kind !== "agm" || event.financialYearEndMs === undefined) return;
  const end = civilFromUtc(event.financialYearEndMs, timeZone);
  const limit = addMonths(end, STATUTE_AGM_OUTER_MONTHS);
  const limitMs = zonedToUtc({ ...limit, hour: 23, minute: 59, second: 59 }, timeZone);
  if (event.atMs > limitMs) {
    errors.push({
      code: "outside_statutory_outer_bound",
      field: "event.financialYearEnd",
      basis: "PGR Art. 339(1)",
      message:
        `The meeting is after ${formatInstant(limitMs, timeZone)}, six calendar months after the financial-year end ` +
        "(day-of-month clamped) in Europe/Vaduz. PGR Art. 179a uses the same six months for the draft financial statement. " +
        COUNSEL,
    });
  }
}

function governorVote(
  articles: NormalizedInput["articles"],
  _labels: NormalizedInput["labels"],
  errors: PlanError[],
): "chain" | "meeting" | "invalid" {
  const delay = articles.votingDelaySeconds;
  const period = articles.votingPeriodSeconds;
  if (delay === undefined && period === undefined) return "meeting";
  if (delay === undefined || period === undefined) {
    errors.push({
      code: "invalid_input",
      field: "articles.votingDelaySeconds",
      message: "votingDelaySeconds and votingPeriodSeconds are set together. They are GvGovernor constructor arguments, in unix seconds.",
    });
    return "invalid";
  }
  if (period === 0) {
    errors.push({
      code: "period_out_of_range",
      field: "articles.votingPeriodSeconds",
      articleSeconds: 0,
      message: "votingPeriodSeconds must be at least 1.",
    });
    return "invalid";
  }
  return "chain";
}

function chainVoteBasis(section: string, appliedSeconds: number): LegalBasis {
  return {
    source: "articles",
    ref: section,
    comparedWith: "GvGovernor votingDelay and votingPeriod; not a PGR period. Art. 332a postal voting is written for EEA-listed companies.",
    configuredSeconds: appliedSeconds,
    appliedSeconds,
    appliedBecause: "configured_value",
    placeholder: false,
    note: `Unix seconds from the meeting instant, treated as the propose time. The chain does not skip weekends. ${COUNSEL}`,
  };
}

function fixedBasis(ref: string, source: Source, appliedSeconds: number, sentence: string, comparedWith?: string): LegalBasis {
  return {
    source,
    ref,
    comparedWith,
    appliedSeconds,
    appliedBecause: "fixed_statutory_offset",
    placeholder: false,
    note: `${sentence} ${COUNSEL}`,
  };
}

function row(input: Omit<Draft, "clock" | "kind"> & { clock?: Clock }, kind: EventKind): Draft {
  return {
    ...input,
    kind,
    clock: input.clock ?? "civil_vaduz",
    basis: clean(input.basis),
  };
}

function compile(
  drafts: Draft[],
  cal: CalendarState,
  asOfMs: number | undefined,
): { deadlines: Deadline[]; warnings: PlanWarning[] } | { error: PlanError } {
  const warnings: PlanWarning[] = [];
  const deadlines: Deadline[] = [];
  for (const draft of drafts) {
    const shifted = applyShift(draft, cal);
    if ("error" in shifted) return shifted;
    if (shifted.adjustment === "none" && draft.warnCode && !isBusinessInstant(shifted.utcMs, cal)) {
      warnings.push({
        code: draft.warnCode,
        message: `${draft.id} falls on a day that is not a business day in ${DEFAULT_TIME_ZONE} and was not moved.`,
      });
    }
    const at = formatInstant(shifted.utcMs, cal.timeZone);
    deadlines.push({
      id: draft.id,
      at,
      atMs: shifted.utcMs,
      action: draft.action,
      audiences: draft.audiences,
      templateKey: templateKey(draft.kind, draft.id),
      latestSendAt: at,
      legalBasis: draft.basis,
      businessDayAdjustment: shifted.adjustment,
      clock: draft.clock,
      onChain: draft.onChain,
      due: asOfMs === undefined ? "unspecified" : shifted.utcMs <= asOfMs ? "past" : "upcoming",
      rank: draft.rank,
    });
  }
  deadlines.sort((a, b) => a.atMs - b.atMs || a.rank - b.rank || a.id.localeCompare(b.id));
  return { deadlines, warnings };
}

function applyShift(
  draft: Draft,
  cal: CalendarState,
): { utcMs: number; adjustment: BusinessDayAdjustment } | { error: PlanError } {
  const keep = { utcMs: draft.utcMs, adjustment: "none" as const };
  if (draft.shift === "unix" || draft.shift === "fixed" || draft.shift === "anchor" || cal.convention === "none") {
    return keep;
  }
  if (isBusinessInstant(draft.utcMs, cal)) return keep;
  if (draft.shift === "latest_by") {
    const prev = adjacentBusiness(draft.utcMs, -1, cal);
    if (prev === null) return { error: noBusinessDay(draft.id) };
    if (draft.notBeforeMs !== undefined && prev < draft.notBeforeMs) return keep;
    return { utcMs: prev, adjustment: "previous_business_day" };
  }
  const next = adjacentBusiness(draft.utcMs, 1, cal);
  if (next === null) return { error: noBusinessDay(draft.id) };
  return { utcMs: next, adjustment: "next_business_day" };
}

function noBusinessDay(id: string): PlanError {
  return {
    code: "no_business_day",
    field: "calendar.holidays",
    message: `No business day within 21 days of ${id}. Check calendar.holidays.`,
  };
}

function templateKey(kind: EventKind, id: string): string {
  const prefix =
    kind === "capital_increase" ? "preemption" : kind === "drag_along" ? "drag" : kind === "tag_along" ? "tag" : kind;
  const leaf: Record<string, string> = {
    notice_dispatch: "notice",
    class_notice_dispatch: "class_notice",
    information_available: "information",
    website_documents: "website",
    agenda_request_close: "agenda_request",
    custody_confirmation: "custody",
    record_date: "record",
    dividend_record: "record",
    voting_open: "voting_open",
    voting_close: "voting_close",
    meeting: "meeting",
    minutes_publication: "minutes",
    minutes_available: "minutes",
    information_response_close: "information_response",
    dividend_claim_open: "claim_open",
    dividend_claim_close: "claim_close",
    preemption_open: "open",
    preemption_close: "close",
    drag_notice: "notice",
    drag_response_close: "response_close",
    tag_notice: "notice",
    tag_response_close: "response_close",
  };
  return `${prefix}.${leaf[id] ?? id}`;
}

function notificationsFor(deadlines: Deadline[], norm: NormalizedInput): SimulatedNotification[] {
  const record = deadlines.find((item) => item.id === "record_date" || item.id === "dividend_record");
  const out: SimulatedNotification[] = [];
  for (const deadline of deadlines) {
    for (const audience of deadline.audiences) {
      out.push({
        deadlineId: deadline.id,
        templateKey: deadline.templateKey,
        audience,
        latestSendAt: deadline.latestSendAt,
        signed: false,
        transmitted: false,
        channel: "simulated",
        recipientTiming:
          record && deadline.atMs < record.atMs ? "register_not_yet_fixed" : "caller_supplied_snapshot",
        recipients: recipients(audience, norm),
        payload: {
          templateKey: deadline.templateKey,
          issuerId: norm.issuerId,
          eventKind: norm.event.kind,
          eventId: norm.event.id,
          deadlineId: deadline.id,
          at: deadline.at,
          legalBasisRef: deadline.legalBasis.ref,
          legalBasisSource: deadline.legalBasis.source,
          signed: false,
          transmitted: false,
        },
      });
    }
  }
  return out;
}

function recipients(audience: Audience, norm: NormalizedInput): SimulatedNotification["recipients"] {
  if (audience === "board") return norm.board.map((address) => ({ address, role: "board" }));
  const holders =
    audience === "affected_class" ? norm.holders.filter((holder) => holder.classId === norm.event.classId) : norm.holders;
  return holders.map((holder) =>
    holder.classId ? { address: holder.address, role: "holder", classId: holder.classId } : { address: holder.address, role: "holder" },
  );
}

function affectedWarning(deadlines: Deadline[], norm: NormalizedInput): PlanWarning[] {
  if (!norm.event.classId) return [];
  const needs = deadlines.some((item) => item.audiences.includes("affected_class"));
  if (!needs) return [];
  const matches = norm.holders.some((holder) => holder.classId === norm.event.classId);
  if (matches) return [];
  return [
    {
      code: "no_affected_holders",
      message: `No supplied holder has classId ${norm.event.classId}. The affected-class notification has an empty recipient list.`,
    },
  ];
}

function noticeOrderWarning(deadlines: Deadline[]): PlanWarning[] {
  const notice = deadlines.find((item) => item.id === "notice_dispatch");
  const info = deadlines.find((item) => item.id === "information_available");
  if (!notice || !info || notice.atMs <= info.atMs) return [];
  return [
    {
      code: "notice_after_information_availability",
      message:
        "The invitation is dispatched after the document-availability instant. PGR Art. 336 and Art. 167 are separate duties. Confirm the notice tells holders where the documents are.",
    },
  ];
}

function span(event: NormalizedEvent, deadlines: Deadline[]): { id: string; kind: EventKind; min: number; max: number } {
  const times = deadlines.map((item) => item.atMs);
  return { id: event.id, kind: event.kind, min: Math.min(...times), max: Math.max(...times) };
}

function overlapsOf(
  spans: Array<{ id: string; kind: EventKind; min: number; max: number }>,
  timeZone: string,
): Overlap[] {
  const out: Overlap[] = [];
  for (let i = 0; i < spans.length; i++) {
    for (let j = i + 1; j < spans.length; j++) {
      const left = spans[i]!;
      const right = spans[j]!;
      const startMs = Math.max(left.min, right.min);
      const endMs = Math.min(left.max, right.max);
      if (startMs > endMs) continue;
      out.push({
        eventId: left.id,
        eventKind: left.kind,
        otherEventId: right.id,
        otherKind: right.kind,
        start: formatInstant(startMs, timeZone),
        end: formatInstant(endMs, timeZone),
        startMs,
        endMs,
      });
    }
  }
  return out;
}

function calendarFor(norm: NormalizedInput): CalendarState {
  const years = new Set<number>();
  const stamps = [norm.event.atMs, norm.event.financialYearEndMs, norm.asOfMs];
  for (const event of norm.otherEvents) stamps.push(event.atMs, event.financialYearEndMs);
  for (const ms of stamps) {
    if (ms === undefined) continue;
    const year = civilFromUtc(ms, DEFAULT_TIME_ZONE).year;
    years.add(year - 1);
    years.add(year);
    years.add(year + 1);
  }
  return {
    timeZone: DEFAULT_TIME_ZONE,
    holidays: holidaySet([...years], norm.holidays, norm.useLiechtensteinPreset),
    convention: norm.convention,
  };
}

function failure(planId: string, issuerId: string | null, errors: PlanError[]): PlanResult {
  return {
    ok: false,
    tool: TOOL_NAME,
    tier: "free",
    signed: false,
    transmitted: false,
    disclaimer: DISCLAIMER,
    issuerId,
    eventId: null,
    timeZone: DEFAULT_TIME_ZONE,
    deadlines: [],
    notifications: [],
    errors,
    warnings: [],
    overlaps: [],
    premium: PREMIUM,
    planId,
  };
}

function publicIssuer(input: unknown): string | null {
  if (!input || typeof input !== "object") return null;
  const id = (input as { issuerId?: unknown }).issuerId;
  return typeof id === "string" && /^[a-z0-9][a-z0-9-]{0,63}$/.test(id) ? id : null;
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function canonical(value: unknown): string {
  if (value === undefined) return "null";
  if (value === null || typeof value !== "object") return JSON.stringify(value) ?? "null";
  if (Array.isArray(value)) return `[${value.map((item) => canonical(item)).join(",")}]`;
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record)
    .filter((key) => record[key] !== undefined)
    .sort();
  return `{${keys.map((key) => `${JSON.stringify(key)}:${canonical(record[key])}`).join(",")}}`;
}

function dedupe(errors: PlanError[]): PlanError[] {
  const seen = new Set<string>();
  const out: PlanError[] = [];
  for (const error of errors) {
    const key = `${error.code}|${error.field}|${error.basis ?? ""}|${error.articleSeconds ?? ""}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(error);
  }
  return out;
}

function dedupeWarnings(warnings: PlanWarning[]): PlanWarning[] {
  const seen = new Set<string>();
  const out: PlanWarning[] = [];
  for (const warning of warnings) {
    if (seen.has(warning.code)) continue;
    seen.add(warning.code);
    out.push(warning);
  }
  out.sort((a, b) => a.code.localeCompare(b.code));
  return out;
}

function clean(basis: LegalBasis): LegalBasis {
  const copy = { ...basis };
  for (const key of Object.keys(copy) as (keyof LegalBasis)[]) {
    if (copy[key] === undefined) delete copy[key];
  }
  return copy;
}

export type { PlanInput };
