// defaults to verify with Liechtenstein counsel
//
// Not legal advice. Not a reading of the Personen- und Gesellschaftsrecht (PGR)
// that an issuer may rely on. Day counts below are taken from the unofficial
// English translation of the PGR, LR 216.0, published by the Government of
// Liechtenstein, translation date 25 October 2023 (the PDF notes a last change
// of 1 August 2023). The German text on gesetze.li is the text that counts.
// A day in this file is 86_400 seconds. "Fourteen days" in the translation is
// applied as fourteen civil days in Europe/Vaduz, not as fourteen business days.

/** Solidity `1 days`. GvCompanyRules stores periods in seconds. */
export const SECONDS_PER_DAY = 86_400;

/** GvCompanyRules.MAX_PERIOD. A software bound, not a statutory maximum. */
export const MAX_PERIOD_SECONDS = 366 * SECONDS_PER_DAY;

/**
 * PGR Art. 167(3). At least one week in the national newspapers, unless the
 * law or the articles provide otherwise. The engine treats one week as a floor
 * until `counselPermitsShorterConveningNotice` is set. That flag is a record
 * that counsel decided, not a legal opinion.
 */
export const STATUTE_CONVENING_NOTICE_SECONDS = 7 * SECONDS_PER_DAY;

/** PGR Art. 339a(1). EEA-listed companies: at the latest 30 days before the general meeting. */
export const STATUTE_LISTED_NOTICE_SECONDS = 30 * SECONDS_PER_DAY;

/**
 * PGR Art. 339a(3). Listed, non-ordinary meeting, electronic voting open to every
 * shareholder, and a prior two-thirds resolution: at the latest 21 days before.
 */
export const STATUTE_LISTED_OTHER_NOTICE_SECONDS = 21 * SECONDS_PER_DAY;

/** PGR Art. 336(1). Business report available at the latest twenty days before the ordinary general meeting. */
export const STATUTE_AGM_INFORMATION_LEAD_SECONDS = 20 * SECONDS_PER_DAY;

/** PGR Art. 339e(1). Listed companies: website information from at the latest 21 days before the meeting. */
export const STATUTE_LISTED_WEBSITE_LEAD_SECONDS = 21 * SECONDS_PER_DAY;

/** PGR Art. 339d(2). Listed ordinary meeting: agenda requests at the latest 21 days before. */
export const STATUTE_LISTED_AGENDA_REQUEST_SECONDS = 21 * SECONDS_PER_DAY;

/** PGR Art. 339c(1). Listed bearer shares: end of the 12th day before the meeting. */
export const STATUTE_LISTED_BEARER_RECORD_DAYS = 12;

/** PGR Art. 339c(1). Custody confirmation no later than the sixth working day before the meeting. */
export const STATUTE_LISTED_BEARER_CUSTODY_WORKING_DAYS = 6;

/** PGR Art. 340a(3). Listed companies publish the voting results within seven days. */
export const STATUTE_LISTED_RESULTS_SECONDS = 7 * SECONDS_PER_DAY;

/** PGR Art. 303(2). The subscription period may not be shorter than fourteen days. */
export const STATUTE_PREEMPTION_SECONDS = 14 * SECONDS_PER_DAY;

/** PGR Art. 339(1) and Art. 179a. Counted as calendar months in Europe/Vaduz. */
export const STATUTE_AGM_OUTER_MONTHS = 6;

/**
 * Software placeholders. They match GvCompanyRules or the lifecycle simulation.
 * They are not PGR periods.
 *
 * defaults to verify with Liechtenstein counsel
 */
export const PLACEHOLDER_RESPONSE_WINDOW_SECONDS = 30 * SECONDS_PER_DAY;
export const PLACEHOLDER_DIVIDEND_CLAIM_SECONDS = 180 * SECONDS_PER_DAY;
export const PLACEHOLDER_DIVIDEND_RECORD_LEAD_SECONDS = 0;
export const PLACEHOLDER_DRAG_RESPONSE_SECONDS = 14 * SECONDS_PER_DAY;
export const PLACEHOLDER_TAG_RESPONSE_SECONDS = 14 * SECONDS_PER_DAY;

export const DEFAULT_TIME_ZONE = "Europe/Vaduz" as const;

/**
 * Business-day convention of this module. Not a PGR article.
 *
 * defaults to verify with Liechtenstein counsel
 *
 * notice_earlier_window_later: a latest-by instant that is not a business day
 * moves to the previous business day. A window-end the operator can still
 * choose moves to the next business day. The meeting instant does not move.
 * A close that GvShareTerms computes as block.timestamp plus seconds does not
 * move either; the plan warns instead.
 */
export const DEFAULT_BUSINESS_DAY_CONVENTION = "notice_earlier_window_later" as const;

export const MAX_OTHER_EVENTS = 64;
export const MAX_HOLDERS = 10_000;
export const MAX_BOARD = 50;

export const TOOL_NAME = "governance.plan_lifecycle_event";
export const PREMIUM_TOOL_NAME = "governance.plan_lifecycle_calendar";

export const PREMIUM_NOTE =
  "Multi-issuer calendar. This module does not price it, does not take payment, and does not call a network. " +
  "Where a paid company-law workflow is offered, it is via a licensed partner (in review).";

export const DISCLAIMER =
  "Not legal advice. defaults to verify with Liechtenstein counsel. " +
  "This plan is an unsigned simulation. Nothing was signed, nothing was sent, and no payment was taken. " +
  "Where a paid company-law workflow is offered, it is via a licensed partner (in review).";
