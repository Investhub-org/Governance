import { DEFAULT_TIME_ZONE } from "./statutory-defaults.ts";
import type { Convention } from "./types.ts";

export interface Civil {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
}

export interface CalendarState {
  timeZone: typeof DEFAULT_TIME_ZONE;
  holidays: ReadonlySet<string>;
  convention: Convention;
}

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timeZone: string): Intl.DateTimeFormat {
  let fmt = formatters.get(timeZone);
  if (!fmt) {
    fmt = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      weekday: "short",
    });
    formatters.set(timeZone, fmt);
  }
  return fmt;
}

export function civilFromUtc(utcMs: number, timeZone: string): Civil & { weekday: string } {
  const bag: Record<string, string> = {};
  for (const part of formatter(timeZone).formatToParts(new Date(utcMs))) {
    if (part.type !== "literal") bag[part.type] = part.value;
  }
  let hour = Number(bag.hour);
  if (hour === 24) hour = 0;
  return {
    year: Number(bag.year),
    month: Number(bag.month),
    day: Number(bag.day),
    hour,
    minute: Number(bag.minute),
    second: Number(bag.second),
    weekday: bag.weekday ?? "",
  };
}

export function zonedToUtc(civil: Civil, timeZone: string): number {
  const guess = Date.UTC(civil.year, civil.month - 1, civil.day, civil.hour, civil.minute, civil.second);
  let utc = guess;
  for (let i = 0; i < 2; i++) {
    const seen = civilFromUtc(utc, timeZone);
    const asUtc = Date.UTC(seen.year, seen.month - 1, seen.day, seen.hour, seen.minute, seen.second);
    utc = guess - (asUtc - utc);
  }
  return utc;
}

export function formatInstant(utcMs: number, timeZone: string): string {
  const p = civilFromUtc(utcMs, timeZone);
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  const offsetMin = Math.round((asUtc - utcMs) / 60_000);
  const sign = offsetMin >= 0 ? "+" : "-";
  const abs = Math.abs(offsetMin);
  const hh = String(Math.floor(abs / 60)).padStart(2, "0");
  const mm = String(abs % 60).padStart(2, "0");
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${p.year}-${pad(p.month)}-${pad(p.day)}T${pad(p.hour)}:${pad(p.minute)}:${pad(p.second)}${sign}${hh}:${mm}`;
}

const ISO = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(Z|[+-]\d{2}:\d{2})$/;

export function parseInstant(iso: string): number | null {
  const match = ISO.exec(iso);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  if (month < 1 || month > 12 || day < 1 || hour > 23 || minute > 59 || second > 59) return null;
  const utc = Date.UTC(year, month - 1, day, hour, minute, second);
  const check = new Date(utc);
  if (
    check.getUTCFullYear() !== year ||
    check.getUTCMonth() !== month - 1 ||
    check.getUTCDate() !== day ||
    check.getUTCHours() !== hour
  ) {
    return null;
  }
  const zone = match[7]!;
  if (zone === "Z") return utc;
  const sign = zone.startsWith("-") ? -1 : 1;
  const zh = Number(zone.slice(1, 3));
  const zm = Number(zone.slice(4, 6));
  if (zh > 14 || zm > 59) return null;
  return utc - sign * (zh * 60 + zm) * 60_000;
}

export function dateKey(civil: { year: number; month: number; day: number }): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${civil.year}-${pad(civil.month)}-${pad(civil.day)}`;
}

export function isRealDate(isoDate: string): boolean {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(isoDate);
  if (!match) return false;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const utc = Date.UTC(year, month - 1, day);
  const check = new Date(utc);
  return check.getUTCFullYear() === year && check.getUTCMonth() === month - 1 && check.getUTCDate() === day;
}

export function addDays(civil: { year: number; month: number; day: number }, days: number): {
  year: number;
  month: number;
  day: number;
} {
  const utc = new Date(Date.UTC(civil.year, civil.month - 1, civil.day + days));
  return { year: utc.getUTCFullYear(), month: utc.getUTCMonth() + 1, day: utc.getUTCDate() };
}

export function addMonths(civil: { year: number; month: number; day: number }, months: number): {
  year: number;
  month: number;
  day: number;
} {
  const total = civil.month - 1 + months;
  const year = civil.year + Math.floor(total / 12);
  const monthIndex = ((total % 12) + 12) % 12;
  const dim = new Date(Date.UTC(year, monthIndex + 1, 0)).getUTCDate();
  return { year, month: monthIndex + 1, day: Math.min(civil.day, dim) };
}

export function shiftByPeriod(utcMs: number, seconds: number, timeZone: string): number {
  const sign = seconds < 0 ? -1 : 1;
  const abs = Math.abs(seconds);
  const days = Math.floor(abs / 86_400);
  const rem = abs % 86_400;
  const p = civilFromUtc(utcMs, timeZone);
  const next = addDays(p, sign * days);
  const moved = zonedToUtc({ ...next, hour: p.hour, minute: p.minute, second: p.second }, timeZone);
  return moved + sign * rem * 1000;
}

export function endOfCivilDay(utcMs: number, timeZone: string): number {
  const p = civilFromUtc(utcMs, timeZone);
  return zonedToUtc({ ...p, hour: 23, minute: 59, second: 59 }, timeZone);
}

/** Gregorian computus. Month is 1-12. */
export function easterSunday(year: number): { year: number; month: number; day: number } {
  const a = year % 19;
  const b = Math.floor(year / 100);
  const c = year % 100;
  const d = Math.floor(b / 4);
  const e = b % 4;
  const f = Math.floor((b + 8) / 25);
  const g = Math.floor((b - f + 1) / 3);
  const h = (19 * a + b - d - g + 15) % 30;
  const i = Math.floor(c / 4);
  const k = c % 4;
  const l = (32 + 2 * e + 2 * i - h - k) % 7;
  const m = Math.floor((a + 11 * h + 22 * l) / 451);
  const month = Math.floor((h + l - 7 * m + 114) / 31);
  const day = ((h + l - 7 * m + 114) % 31) + 1;
  return { year, month, day };
}

/**
 * Public-holiday preset for the engine.
 *
 * defaults to verify with Liechtenstein counsel
 *
 * Fixed dates plus Good Friday, Easter Monday, Ascension, Whit Monday, and
 * Corpus Christi. 2 January (Berchtoldstag) is not in this preset. The list is
 * a configurable default, not an official calendar.
 */
export function liechtensteinHolidayDates(year: number): string[] {
  const fixed = ["01-01", "01-06", "02-02", "03-19", "05-01", "08-15", "09-08", "11-01", "12-08", "12-25", "12-26"];
  const easter = easterSunday(year);
  const movable = [-2, 1, 39, 50, 60].map((delta) => dateKey(addDays(easter, delta)));
  return [...fixed.map((md) => `${year}-${md}`), ...movable];
}

export function holidaySet(years: number[], extra: readonly string[], usePreset: boolean): Set<string> {
  const set = new Set<string>(extra);
  if (usePreset) {
    for (const year of years) {
      for (const day of liechtensteinHolidayDates(year)) set.add(day);
    }
  }
  return set;
}

export function isBusinessInstant(utcMs: number, cal: CalendarState): boolean {
  const p = civilFromUtc(utcMs, cal.timeZone);
  if (p.weekday === "Sat" || p.weekday === "Sun") return false;
  return !cal.holidays.has(dateKey(p));
}

/** Step at least one civil day. Keeps the local time. Null when none is found within 21 days. */
export function adjacentBusiness(utcMs: number, dir: -1 | 1, cal: CalendarState): number | null {
  const p = civilFromUtc(utcMs, cal.timeZone);
  let cursor = { year: p.year, month: p.month, day: p.day };
  for (let i = 0; i < 21; i++) {
    cursor = addDays(cursor, dir);
    const candidate = zonedToUtc(
      { ...cursor, hour: p.hour, minute: p.minute, second: p.second },
      cal.timeZone,
    );
    if (isBusinessInstant(candidate, cal)) return candidate;
  }
  return null;
}

/** The nth working day before the meeting date, end of that civil day. The meeting date is not counted. */
export function workingDaysBefore(meetingMs: number, count: number, cal: CalendarState): number | null {
  const start = civilFromUtc(meetingMs, cal.timeZone);
  let cursor = { year: start.year, month: start.month, day: start.day };
  let seen = 0;
  for (let i = 0; i < 366; i++) {
    cursor = addDays(cursor, -1);
    const noon = zonedToUtc({ ...cursor, hour: 12, minute: 0, second: 0 }, cal.timeZone);
    if (!isBusinessInstant(noon, cal)) continue;
    seen += 1;
    if (seen === count) {
      return zonedToUtc({ ...cursor, hour: 23, minute: 59, second: 59 }, cal.timeZone);
    }
  }
  return null;
}
