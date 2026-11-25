import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { easterSunday, liechtensteinHolidayDates } from "../calendar.ts";
import {
  PLAN_LIFECYCLE_EVENT_TOOL,
  SECONDS_PER_DAY,
  planLifecycleEvent,
} from "../index.ts";
import type { PlanResult } from "../types.ts";

const DAY = SECONDS_PER_DAY;
const MEETING = "2026-07-15T10:00:00+02:00";
const QUIET = { convention: "none" as const, useLiechtensteinPreset: false, holidays: [] as string[] };

const HOLDERS = [
  { address: "0xA11CE00000000000000000000000000000000001", classId: "ordinary" },
  { address: "0xA11CE00000000000000000000000000000000002", classId: "preferred" },
];
const BOARD = ["0xB0A4D00000000000000000000000000000000001"];

function plan(event: Record<string, unknown>, extra: Record<string, unknown> = {}): PlanResult {
  return planLifecycleEvent({
    issuerId: "synthetic-issuer-001",
    calendar: QUIET,
    event,
    ...extra,
  });
}

function at(result: PlanResult, id: string) {
  const row = result.deadlines.find((item) => item.id === id);
  assert.ok(row, `missing ${id}; have ${result.deadlines.map((item) => item.id).join(", ")} / ${result.errors.map((item) => item.field).join(", ")}`);
  return row;
}

test("statutory defaults file carries the counsel comment", () => {
  const text = readFileSync(new URL("../statutory-defaults.ts", import.meta.url), "utf8");
  assert.ok(text.includes("defaults to verify with Liechtenstein counsel"));
  assert.match(text, /not legal advice/i);
});

test("easter and the Liechtenstein preset", () => {
  assert.deepEqual(easterSunday(2024), { year: 2024, month: 3, day: 31 });
  assert.deepEqual(easterSunday(2025), { year: 2025, month: 4, day: 20 });
  assert.deepEqual(easterSunday(2026), { year: 2026, month: 4, day: 5 });
  const days = liechtensteinHolidayDates(2026);
  for (const day of ["2026-01-01", "2026-08-15", "2026-04-03", "2026-04-06", "2026-12-25", "2026-12-26"]) {
    assert.ok(days.includes(day), day);
  }
  assert.equal(days.includes("2026-01-02"), false);
});

test("tool document is a free read and leaves the multi-issuer calendar unimplemented", () => {
  const tool = PLAN_LIFECYCLE_EVENT_TOOL as {
    name: string;
    tier: string;
    signs: boolean;
    transmits: boolean;
    premium: { name: string; tier: string; implemented: boolean };
    outputSchema: { required: string[] };
  };
  assert.equal(tool.name, "governance.plan_lifecycle_event");
  assert.equal(tool.tier, "free");
  assert.equal(tool.signs, false);
  assert.equal(tool.transmits, false);
  assert.equal(tool.premium.name, "governance.plan_lifecycle_calendar");
  assert.equal(tool.premium.tier, "x402");
  assert.equal(tool.premium.implemented, false);
  const sample = plan({ kind: "agm", at: MEETING });
  for (const key of tool.outputSchema.required) assert.ok(key in sample, key);
  assert.equal(sample.premium.implemented, false);
  assert.equal(sample.signed, false);
  assert.equal(sample.transmitted, false);
  assert.match(sample.disclaimer, /defaults to verify with Liechtenstein counsel/);
  assert.match(sample.disclaimer, /licensed partner \(in review\)/);
});

test("table: meetings, dividend, pre-emption, drag, and tag", () => {
  const cases: Array<{
    name: string;
    event: Record<string, unknown>;
    extra?: Record<string, unknown>;
    ok?: boolean;
    ids?: string[];
    at?: Record<string, string>;
    source?: Record<string, string>;
    because?: Record<string, string>;
    ref?: Record<string, string>;
    absent?: string[];
    warnings?: string[];
    noWarnings?: string[];
    errors?: Array<{ code: string; field?: string; basis?: string }>;
  }> = [
    {
      name: "silent AGM uses the one-week notice and the twenty-day report",
      event: { kind: "agm", at: MEETING },
      ids: [
        "information_available",
        "notice_dispatch",
        "record_date",
        "voting_open",
        "meeting",
        "voting_close",
        "minutes_available",
        "information_response_close",
      ],
      at: {
        information_available: "2026-06-25T10:00:00+02:00",
        notice_dispatch: "2026-07-08T10:00:00+02:00",
        record_date: MEETING,
        meeting: MEETING,
        information_response_close: "2026-08-14T10:00:00+02:00",
      },
      source: { notice_dispatch: "statute", information_available: "statute", information_response_close: "articles" },
      ref: { notice_dispatch: "PGR Art. 167(3)", information_available: "PGR Art. 336(1)" },
      because: { notice_dispatch: "statutory_default", information_response_close: "software_placeholder" },
      warnings: ["notice_after_information_availability"],
    },
    {
      name: "a longer AGM notice wins and is dispatched before the report",
      event: { kind: "agm", at: MEETING },
      extra: { articles: { agmNoticeSeconds: 21 * DAY } },
      at: { notice_dispatch: "2026-06-24T10:00:00+02:00" },
      source: { notice_dispatch: "articles" },
      because: { notice_dispatch: "longer_than_default" },
      ref: { notice_dispatch: "articles §meetings" },
      noWarnings: ["notice_after_information_availability"],
    },
    {
      name: "EGM notice longer than one week is the article period",
      event: { kind: "egm", at: MEETING },
      extra: { articles: { egmNoticeSeconds: 10 * DAY } },
      at: { notice_dispatch: "2026-07-05T10:00:00+02:00" },
      source: { notice_dispatch: "articles" },
      because: { notice_dispatch: "longer_than_default" },
      absent: ["information_available", "website_documents", "agenda_request_close"],
    },
    {
      name: "listed EGM with electronic voting uses the 21-day statute",
      event: { kind: "egm", at: MEETING },
      extra: { articles: { eeaListed: true, electronicVotingOpen: true } },
      at: { notice_dispatch: "2026-06-24T10:00:00+02:00", website_documents: "2026-06-24T10:00:00+02:00" },
      source: { notice_dispatch: "statute", website_documents: "statute" },
      ref: { notice_dispatch: "PGR Art. 339a(3)", website_documents: "PGR Art. 339e(1)" },
      absent: ["agenda_request_close", "information_available"],
    },
    {
      name: "listed EGM without electronic voting stays at 30 days",
      event: { kind: "egm", at: MEETING },
      extra: { articles: { eeaListed: true } },
      at: { notice_dispatch: "2026-06-15T10:00:00+02:00" },
      ref: { notice_dispatch: "PGR Art. 339a(1)" },
    },
    {
      name: "listed bearer AGM fixes the record date and the custody day",
      event: { kind: "agm", at: MEETING },
      extra: { articles: { eeaListed: true, shareForm: "bearer" } },
      ids: [
        "notice_dispatch",
        "website_documents",
        "agenda_request_close",
        "information_available",
        "record_date",
        "custody_confirmation",
        "voting_open",
        "meeting",
        "voting_close",
        "minutes_publication",
        "information_response_close",
      ],
      at: {
        notice_dispatch: "2026-06-15T10:00:00+02:00",
        website_documents: "2026-06-24T10:00:00+02:00",
        information_available: "2026-06-25T10:00:00+02:00",
        record_date: "2026-07-03T23:59:59+02:00",
        custody_confirmation: "2026-07-07T23:59:59+02:00",
        minutes_publication: "2026-07-22T10:00:00+02:00",
      },
      ref: { record_date: "PGR Art. 339c(1)", minutes_publication: "PGR Art. 340a(3)" },
      source: { minutes_publication: "statute" },
    },
    {
      name: "dividend record and claim use article placeholders, not a PGR day count",
      event: { kind: "dividend", at: MEETING },
      at: {
        dividend_record: MEETING,
        dividend_claim_open: MEETING,
        dividend_claim_close: "2027-01-11T10:00:00+01:00",
      },
      source: { dividend_claim_close: "articles" },
      because: { dividend_claim_close: "software_placeholder" },
      ref: { dividend_claim_close: "articles §dividend" },
    },
    {
      name: "a shorter dividend claim window is allowed",
      event: { kind: "dividend", at: MEETING },
      extra: { articles: { dividendRecordLeadSeconds: 2 * DAY, dividendClaimWindowSeconds: 30 * DAY } },
      at: {
        dividend_record: "2026-07-13T10:00:00+02:00",
        dividend_claim_close: "2026-08-14T10:00:00+02:00",
      },
      source: { dividend_claim_close: "articles" },
      because: { dividend_claim_close: "configured_value" },
    },
    {
      name: "a longer pre-emption window wins",
      event: { kind: "capital_increase", at: "2026-07-01T10:00:00+02:00" },
      extra: { articles: { preEmptionWindowSeconds: 21 * DAY } },
      at: { preemption_open: "2026-07-01T10:00:00+02:00", preemption_close: "2026-07-22T10:00:00+02:00" },
      source: { preemption_close: "articles" },
      because: { preemption_close: "longer_than_default" },
      ref: { preemption_close: "articles §parameters" },
    },
    {
      name: "pre-emption keeps civil days across the spring clock change",
      event: { kind: "capital_increase", at: "2026-03-20T10:00:00+01:00" },
      at: { preemption_close: "2026-04-03T10:00:00+02:00" },
      source: { preemption_close: "statute" },
      ref: { preemption_close: "PGR Art. 303(2)" },
    },
    {
      name: "drag-along close is the shareholder agreement",
      event: { kind: "drag_along", at: "2026-07-01T10:00:00+02:00" },
      at: { drag_notice: "2026-07-01T10:00:00+02:00", drag_response_close: "2026-07-15T10:00:00+02:00" },
      source: { drag_response_close: "sha" },
      because: { drag_response_close: "software_placeholder" },
      ref: { drag_notice: "shareholder agreement §drag-along", drag_response_close: "shareholder agreement §drag-along" },
      warnings: ["sha_window_not_a_statute"],
    },
    {
      name: "a shorter tag-along window is not a statutory error",
      event: { kind: "tag_along", at: "2026-07-01T10:00:00+02:00" },
      extra: { sha: { tagResponseSeconds: 10 * DAY } },
      at: { tag_response_close: "2026-07-11T10:00:00+02:00" },
      source: { tag_response_close: "sha" },
      because: { tag_response_close: "configured_value" },
      warnings: ["sha_window_not_a_statute"],
    },
    {
      name: "a ten-day information response is not below a statutory minimum",
      event: { kind: "agm", at: MEETING },
      extra: { articles: { responseWindowSeconds: 10 * DAY } },
      at: { information_response_close: "2026-07-25T10:00:00+02:00" },
      because: { information_response_close: "configured_value" },
    },
  ];

  for (const item of cases) {
    const result = plan(item.event, item.extra);
    assert.equal(result.ok, item.ok !== false, `${item.name}: ${JSON.stringify(result.errors)}`);
    if (item.ids) assert.deepEqual(result.deadlines.map((row) => row.id), item.ids, item.name);
    for (const [id, iso] of Object.entries(item.at ?? {})) {
      assert.equal(at(result, id).at, iso, `${item.name} ${id}`);
    }
    for (const [id, source] of Object.entries(item.source ?? {})) {
      assert.equal(at(result, id).legalBasis.source, source, `${item.name} ${id} source`);
    }
    for (const [id, because] of Object.entries(item.because ?? {})) {
      assert.equal(at(result, id).legalBasis.appliedBecause, because, `${item.name} ${id} because`);
    }
    for (const [id, ref] of Object.entries(item.ref ?? {})) {
      const basis = at(result, id).legalBasis;
      assert.equal(basis.ref === ref || basis.comparedWith === ref, true, `${item.name} ${id} ref ${basis.ref} compared ${basis.comparedWith}`);
    }
    for (const id of item.absent ?? []) {
      assert.equal(result.deadlines.some((row) => row.id === id), false, `${item.name} has ${id}`);
    }
    for (const code of item.warnings ?? []) {
      assert.ok(result.warnings.some((warning) => warning.code === code), `${item.name} warning ${code}`);
    }
    for (const code of item.noWarnings ?? []) {
      assert.equal(result.warnings.some((warning) => warning.code === code), false, `${item.name} unexpected ${code}`);
    }
  }
});

test("table: validation errors", () => {
  const cases: Array<{
    name: string;
    event: Record<string, unknown>;
    extra?: Record<string, unknown>;
    errors: Array<{ code: string; field?: string; basis?: string }>;
  }> = [
    {
      name: "pre-emption shorter than fourteen days",
      event: { kind: "capital_increase", at: "2026-07-01T10:00:00+02:00" },
      extra: { articles: { preEmptionWindowSeconds: 10 * DAY } },
      errors: [{ code: "below_statutory_minimum", field: "articles.preEmptionWindowSeconds", basis: "PGR Art. 303(2)" }],
    },
    {
      name: "the counsel flag does not waive the subscription floor",
      event: { kind: "capital_increase", at: "2026-07-01T10:00:00+02:00" },
      extra: { articles: { preEmptionWindowSeconds: 10 * DAY, counselPermitsShorterConveningNotice: true } },
      errors: [{ code: "below_statutory_minimum", basis: "PGR Art. 303(2)" }],
    },
    {
      name: "private AGM notice shorter than one week",
      event: { kind: "agm", at: MEETING },
      extra: { articles: { agmNoticeSeconds: 3 * DAY } },
      errors: [{ code: "below_statutory_minimum", field: "articles.agmNoticeSeconds", basis: "PGR Art. 167(3)" }],
    },
    {
      name: "report availability shorter than twenty days",
      event: { kind: "agm", at: MEETING },
      extra: { articles: { informationLeadSeconds: 10 * DAY } },
      errors: [{ code: "below_statutory_minimum", field: "articles.informationLeadSeconds", basis: "PGR Art. 336(1)" }],
    },
    {
      name: "notice and report can both fail",
      event: { kind: "agm", at: MEETING },
      extra: { articles: { agmNoticeSeconds: 3 * DAY, informationLeadSeconds: 10 * DAY } },
      errors: [
        { code: "below_statutory_minimum", field: "articles.agmNoticeSeconds" },
        { code: "below_statutory_minimum", field: "articles.informationLeadSeconds" },
      ],
    },
    {
      name: "listed AGM notice shorter than thirty days",
      event: { kind: "agm", at: MEETING },
      extra: { articles: { eeaListed: true, agmNoticeSeconds: 20 * DAY, counselPermitsShorterConveningNotice: true } },
      errors: [{ code: "below_statutory_minimum", basis: "PGR Art. 339a(1)" }],
    },
    {
      name: "listed results later than seven days",
      event: { kind: "agm", at: MEETING },
      extra: { articles: { eeaListed: true, minutesPublicationSeconds: 10 * DAY } },
      errors: [{ code: "above_statutory_maximum", field: "articles.minutesPublicationSeconds", basis: "PGR Art. 340a(3)" }],
    },
    {
      name: "an article record lead cannot replace the bearer record date",
      event: { kind: "agm", at: MEETING },
      extra: { articles: { eeaListed: true, shareForm: "bearer", recordLeadSeconds: DAY } },
      errors: [{ code: "conflicts_with_statute", field: "articles.recordLeadSeconds", basis: "PGR Art. 339c(1)" }],
    },
    {
      name: "ordinary meeting after six months",
      event: { kind: "agm", at: "2026-07-01T10:00:00+02:00", financialYearEnd: "2025-12-31T12:00:00+01:00" },
      errors: [{ code: "outside_statutory_outer_bound", basis: "PGR Art. 339(1)" }],
    },
  ];

  for (const item of cases) {
    const result = plan(item.event, item.extra);
    assert.equal(result.ok, false, item.name);
    assert.deepEqual(result.deadlines, [], item.name);
    assert.deepEqual(result.notifications, [], item.name);
    for (const expected of item.errors) {
      const found = result.errors.find(
        (error) =>
          error.code === expected.code &&
          (expected.field === undefined || error.field === expected.field) &&
          (expected.basis === undefined || error.basis === expected.basis),
      );
      assert.ok(found, `${item.name} missing ${expected.code} ${expected.field ?? ""} in ${JSON.stringify(result.errors)}`);
    }
    assert.equal(result.premium.implemented, false);
  }
});

test("counsel can record a shorter private-company convening notice", () => {
  const result = plan(
    { kind: "agm", at: MEETING },
    { articles: { agmNoticeSeconds: 3 * DAY, counselPermitsShorterConveningNotice: true } },
  );
  assert.equal(result.ok, true, JSON.stringify(result.errors));
  assert.equal(at(result, "notice_dispatch").at, "2026-07-12T10:00:00+02:00");
  assert.equal(at(result, "notice_dispatch").legalBasis.appliedBecause, "counsel_permits_shorter");
  assert.ok(result.warnings.some((warning) => warning.code === "shorter_than_published_statutory_default"));
});

test("an AGM inside six months of the year end is planned", () => {
  const result = plan({
    kind: "agm",
    at: "2026-06-30T10:00:00+02:00",
    financialYearEnd: "2025-12-31T12:00:00+01:00",
  });
  assert.equal(result.ok, true, JSON.stringify(result.errors));
});

test("weekends and configured holidays move send times and chosen window ends", () => {
  const sunday = plan(
    { kind: "agm", at: "2026-06-15T10:00:00+02:00" },
    {
      articles: { agmNoticeSeconds: 8 * DAY },
      calendar: { convention: "notice_earlier_window_later", useLiechtensteinPreset: false, holidays: [] },
    },
  );
  assert.equal(at(sunday, "notice_dispatch").at, "2026-06-05T10:00:00+02:00");
  assert.equal(at(sunday, "notice_dispatch").businessDayAdjustment, "previous_business_day");

  const holiday = plan(
    { kind: "agm", at: "2026-06-15T10:00:00+02:00" },
    {
      articles: { agmNoticeSeconds: 8 * DAY },
      calendar: { convention: "notice_earlier_window_later", useLiechtensteinPreset: false, holidays: ["2026-06-05"] },
    },
  );
  assert.equal(at(holiday, "notice_dispatch").at, "2026-06-04T10:00:00+02:00");

  const newYear = plan(
    { kind: "agm", at: "2026-01-08T10:00:00+01:00" },
    { calendar: { convention: "notice_earlier_window_later", useLiechtensteinPreset: true, holidays: [] } },
  );
  assert.equal(at(newYear, "notice_dispatch").at, "2025-12-31T10:00:00+01:00");
  assert.equal(at(newYear, "notice_dispatch").businessDayAdjustment, "previous_business_day");

  const drag = plan(
    { kind: "drag_along", at: "2026-06-06T10:00:00+02:00" },
    { calendar: { convention: "notice_earlier_window_later", useLiechtensteinPreset: false, holidays: [] } },
  );
  assert.equal(at(drag, "drag_response_close").at, "2026-06-22T10:00:00+02:00");
  assert.equal(at(drag, "drag_response_close").businessDayAdjustment, "next_business_day");
  assert.ok(drag.warnings.some((warning) => warning.code === "anchor_not_business_day"));

  const offer = plan(
    { kind: "capital_increase", at: "2026-06-06T10:00:00+02:00" },
    { calendar: { convention: "notice_earlier_window_later", useLiechtensteinPreset: false, holidays: [] } },
  );
  assert.equal(at(offer, "preemption_close").at, "2026-06-20T10:00:00+02:00");
  assert.equal(at(offer, "preemption_close").businessDayAdjustment, "none");
  assert.ok(offer.warnings.some((warning) => warning.code === "window_ends_on_non_business_day"));
});

test("Europe/Vaduz offsets", () => {
  const winter = plan({ kind: "agm", at: "2026-01-15T09:00:00Z" });
  assert.equal(at(winter, "meeting").at, "2026-01-15T10:00:00+01:00");
  const summer = plan({ kind: "agm", at: "2026-07-15T08:00:00Z" });
  assert.equal(at(summer, "meeting").at, "2026-07-15T10:00:00+02:00");
});

test("governor ballot is unix time and does not move for a weekend", () => {
  const result = plan(
    { kind: "agm", at: MEETING },
    { articles: { votingDelaySeconds: DAY, votingPeriodSeconds: 7 * DAY } },
  );
  assert.equal(result.ok, true, JSON.stringify(result.errors));
  assert.equal(at(result, "voting_open").at, "2026-07-16T10:00:00+02:00");
  assert.equal(at(result, "voting_close").at, "2026-07-23T10:00:00+02:00");
  assert.equal(at(result, "voting_open").clock, "unix");
  assert.equal(at(result, "voting_open").onChain?.contract, "GvGovernor");
  assert.equal(at(result, "voting_close").businessDayAdjustment, "none");
  const missing = plan({ kind: "agm", at: MEETING }, { articles: { votingDelaySeconds: 1 } });
  assert.equal(missing.ok, false);
  assert.equal(missing.errors[0]?.code, "invalid_input");
});

test("asOf marks past and upcoming deadlines", () => {
  const result = plan({ kind: "agm", at: MEETING }, { asOf: "2026-07-01T00:00:00Z" });
  assert.equal(at(result, "information_available").due, "past");
  assert.equal(at(result, "notice_dispatch").due, "upcoming");
});

test("overlapping events of one issuer", () => {
  const result = plan(
    { id: "agm-1", kind: "agm", at: MEETING },
    { otherEvents: [{ id: "raise-1", kind: "capital_increase", at: "2026-07-01T10:00:00+02:00" }] },
  );
  assert.equal(result.ok, true, JSON.stringify(result.errors));
  assert.equal(result.overlaps.length, 1);
  assert.equal(result.overlaps[0]?.eventId, "agm-1");
  assert.equal(result.overlaps[0]?.otherEventId, "raise-1");
  assert.equal(result.overlaps[0]?.otherKind, "capital_increase");
  assert.equal(result.overlaps[0]?.start, "2026-07-01T10:00:00+02:00");
  assert.equal(result.overlaps[0]?.end, "2026-07-15T10:00:00+02:00");
});

test("notifications are unsigned simulated payloads for synthetic addresses", () => {
  const result = plan(
    { kind: "agm", at: MEETING, classId: "preferred" },
    { holders: HOLDERS, board: BOARD },
  );
  assert.equal(result.ok, true, JSON.stringify(result.errors));
  const encoded = JSON.stringify(result);
  assert.equal(encoded.includes("@"), false);
  for (const note of result.notifications) {
    assert.equal(note.signed, false);
    assert.equal(note.transmitted, false);
    assert.equal(note.channel, "simulated");
    assert.equal(note.payload.signed, false);
    assert.equal(note.payload.transmitted, false);
  }
  const classNote = result.notifications.find(
    (note) => note.deadlineId === "class_notice_dispatch" && note.audience === "affected_class",
  );
  assert.deepEqual(classNote?.recipients, [
    { address: "0xa11ce00000000000000000000000000000000002", role: "holder", classId: "preferred" },
  ]);
  const everyone = result.notifications.find(
    (note) => note.deadlineId === "notice_dispatch" && note.audience === "all_holders_at_record_date",
  );
  assert.equal(everyone?.recipients.length, 2);
  assert.equal(everyone?.recipientTiming, "register_not_yet_fixed");
  const board = result.notifications.find((note) => note.deadlineId === "meeting" && note.audience === "board");
  assert.deepEqual(board?.recipients, [{ address: "0xb0a4d00000000000000000000000000000000001", role: "board" }]);
  assert.equal(at(result, "notice_dispatch").latestSendAt, at(result, "notice_dispatch").at);
});

test("the same input plans the same bytes", () => {
  const body = {
    issuerId: "synthetic-issuer-001",
    calendar: QUIET,
    event: { kind: "agm", at: MEETING },
    holders: HOLDERS,
  };
  const first = planLifecycleEvent(body);
  const second = planLifecycleEvent(body);
  assert.equal(JSON.stringify(first), JSON.stringify(second));
  assert.match(first.planId, /^[0-9a-f]{64}$/);
});

test("the schema rejects a second issuer, a bad kind, an email, and a key", () => {
  const badKind = planLifecycleEvent({
    issuerId: "synthetic-issuer-001",
    event: { kind: "picnic", at: MEETING },
  });
  assert.equal(badKind.ok, false);
  assert.equal(badKind.errors[0]?.code, "invalid_input");

  const many = planLifecycleEvent({
    issuerId: "synthetic-issuer-001",
    event: { kind: "agm", at: MEETING },
    issuers: ["synthetic-issuer-002"],
  });
  assert.equal(many.ok, false);
  assert.match(many.errors.map((error) => error.field).join(" "), /issuers/);

  const mail = planLifecycleEvent({
    issuerId: "synthetic-issuer-001",
    event: { kind: "agm", at: MEETING },
    articles: { noticeSection: "desk has@sign" },
  });
  assert.equal(mail.ok, false);

  const key = planLifecycleEvent({
    issuerId: "synthetic-issuer-001",
    event: { kind: "agm", at: MEETING },
    board: [`0x${"ab".repeat(32)}`],
  });
  assert.equal(key.ok, false);
  assert.equal(key.deadlines.length, 0);
});
