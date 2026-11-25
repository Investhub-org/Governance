import { isRealDate, parseInstant } from "./calendar.ts";
import toolDoc from "./schema.json" with { type: "json" };
import { DEFAULT_BUSINESS_DAY_CONVENTION, DEFAULT_TIME_ZONE } from "./statutory-defaults.ts";
import type {
  ArticlesConfig,
  Convention,
  Holder,
  Labels,
  LifecycleEventInput,
  NormalizedEvent,
  NormalizedInput,
  PlanError,
  ShaConfig,
  ShareForm,
} from "./types.ts";

interface Schema {
  type?: string | string[];
  enum?: unknown[];
  const?: unknown;
  properties?: Record<string, Schema>;
  required?: string[];
  additionalProperties?: boolean;
  items?: Schema;
  minimum?: number;
  maximum?: number;
  minItems?: number;
  maxItems?: number;
  pattern?: string;
  $ref?: string;
}

const doc = toolDoc as unknown as { inputSchema: Schema; $defs: Record<string, Schema> };

function refSchema(ref: string): Schema {
  if (!ref.startsWith("#/")) throw new Error(`bad ref ${ref}`);
  const parts = ref.slice(2).split("/");
  let cur: unknown = toolDoc;
  for (const part of parts) {
    if (cur === null || typeof cur !== "object") throw new Error(`bad ref ${ref}`);
    cur = (cur as Record<string, unknown>)[part];
  }
  return cur as Schema;
}

function typeOk(type: string, value: unknown): boolean {
  if (type === "null") return value === null;
  if (type === "object") return typeof value === "object" && value !== null && !Array.isArray(value);
  if (type === "array") return Array.isArray(value);
  if (type === "integer") return typeof value === "number" && Number.isInteger(value);
  if (type === "boolean") return typeof value === "boolean";
  if (type === "string") return typeof value === "string";
  if (type === "number") return typeof value === "number";
  return false;
}

function structural(schema: Schema, value: unknown, path: string, errors: PlanError[]): void {
  if (schema.$ref) {
    structural(refSchema(schema.$ref), value, path, errors);
    return;
  }
  if (schema.const !== undefined) {
    if (value !== schema.const) {
      errors.push(invalid(path, `expected ${JSON.stringify(schema.const)}`));
    }
    return;
  }
  if (schema.enum && !schema.enum.includes(value)) {
    errors.push(invalid(path, `expected one of ${schema.enum.map((item) => JSON.stringify(item)).join(", ")}`));
    return;
  }
  if (schema.type) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((type) => typeOk(type, value))) {
      errors.push(invalid(path, `expected ${types.join(" | ")}`));
      return;
    }
  }
  if (typeof value === "string" && schema.pattern && !new RegExp(schema.pattern).test(value)) {
    errors.push(invalid(path, "does not match the required pattern"));
  }
  if (typeof value === "number") {
    if (schema.minimum !== undefined && value < schema.minimum) {
      errors.push(invalid(path, `below minimum ${schema.minimum}`));
    }
    if (schema.maximum !== undefined && value > schema.maximum) {
      errors.push(invalid(path, `above maximum ${schema.maximum}`));
    }
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(invalid(path, `fewer than ${schema.minItems} items`));
    }
    if (schema.maxItems !== undefined && value.length > schema.maxItems) {
      errors.push(invalid(path, `more than ${schema.maxItems} items`));
    }
    if (schema.items) {
      for (let i = 0; i < value.length; i++) structural(schema.items, value[i], `${path}[${i}]`, errors);
    }
    return;
  }
  if (typeof value === "object" && value !== null && schema.properties) {
    const record = value as Record<string, unknown>;
    if (schema.required) {
      for (const key of schema.required) {
        if (record[key] === undefined) errors.push(invalid(path ? `${path}.${key}` : key, "is required"));
      }
    }
    for (const key of Object.keys(record)) {
      const child = schema.properties[key];
      if (!child) {
        if (schema.additionalProperties === false) errors.push(invalid(path ? `${path}.${key}` : key, "is not a field of this tool"));
        continue;
      }
      structural(child, record[key], path ? `${path}.${key}` : key, errors);
    }
  }
}

function invalid(field: string, message: string): PlanError {
  return { code: "invalid_input", field: field || "$", message: `${field || "input"} ${message}` };
}

function scanStrings(value: unknown, path: string, errors: PlanError[]): void {
  if (typeof value === "string") {
    if (value.includes("@")) {
      errors.push(invalid(path, "must not contain an email address. This tool takes synthetic addresses only."));
    }
    if (/^0x[0-9a-fA-F]{64}$/.test(value)) {
      errors.push(invalid(path, "looks like a private key. Do not pass key material."));
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, i) => scanStrings(item, `${path}[${i}]`, errors));
    return;
  }
  if (value && typeof value === "object") {
    for (const [key, child] of Object.entries(value)) {
      scanStrings(child, path ? `${path}.${key}` : key, errors);
    }
  }
}

function eventFrom(raw: LifecycleEventInput, fallbackId: string, field: string, errors: PlanError[]): NormalizedEvent | null {
  const atMs = parseInstant(raw.at);
  if (atMs === null) {
    errors.push(invalid(`${field}.at`, "is not a real timestamp"));
    return null;
  }
  let financialYearEndMs: number | undefined;
  if (raw.financialYearEnd !== undefined) {
    const parsed = parseInstant(raw.financialYearEnd);
    if (parsed === null) {
      errors.push(invalid(`${field}.financialYearEnd`, "is not a real timestamp"));
      return null;
    }
    financialYearEndMs = parsed;
  }
  return {
    id: raw.id ?? fallbackId,
    kind: raw.kind,
    atMs,
    classId: raw.classId,
    financialYearEndMs,
  };
}

export function validateInput(input: unknown): { value: NormalizedInput } | { errors: PlanError[] } {
  const errors: PlanError[] = [];
  structural(doc.inputSchema, input, "", errors);
  if (input && typeof input === "object") scanStrings(input, "", errors);
  if (errors.length > 0) return { errors: errors.slice(0, 32) };
  const raw = input as {
    issuerId: string;
    event: LifecycleEventInput;
    articles?: ArticlesConfig;
    sha?: ShaConfig;
    calendar?: { holidays?: string[]; useLiechtensteinPreset?: boolean; convention?: Convention };
    holders?: Holder[];
    board?: string[];
    otherEvents?: LifecycleEventInput[];
    asOf?: string;
  };

  for (const day of raw.calendar?.holidays ?? []) {
    if (!isRealDate(day)) errors.push(invalid("calendar.holidays", `${day} is not a calendar date`));
  }

  const holders = (raw.holders ?? []).map((holder) => ({
    address: holder.address.toLowerCase(),
    classId: holder.classId,
  }));
  const seenHolders = new Set<string>();
  for (const holder of holders) {
    if (seenHolders.has(holder.address)) {
      errors.push(invalid("holders", `duplicate address ${holder.address}`));
    }
    seenHolders.add(holder.address);
  }
  const board = (raw.board ?? []).map((address) => address.toLowerCase());

  const event = eventFrom(raw.event, raw.event.kind, "event", errors);
  const otherEvents: NormalizedEvent[] = [];
  for (let i = 0; i < (raw.otherEvents ?? []).length; i++) {
    const item = raw.otherEvents![i]!;
    const parsed = eventFrom(item, item.kind, `otherEvents[${i}]`, errors);
    if (parsed) otherEvents.push(parsed);
  }

  let asOfMs: number | undefined;
  if (raw.asOf !== undefined) {
    const parsed = parseInstant(raw.asOf);
    if (parsed === null) errors.push(invalid("asOf", "is not a real timestamp"));
    else asOfMs = parsed;
  }

  if (!event || errors.length > 0) return { errors: errors.slice(0, 32) };

  const ids = [event.id, ...otherEvents.map((item) => item.id)];
  const seenIds = new Set<string>();
  for (const id of ids) {
    if (seenIds.has(id)) {
      errors.push({
        code: "duplicate_event_id",
        field: "event.id",
        message: `Two events use the id ${id}. Give each event its own id.`,
      });
    }
    seenIds.add(id);
  }
  if (errors.length > 0) return { errors };

  const articles = raw.articles ?? {};
  const sha = raw.sha ?? {};
  const labels: Labels = {
    noticeSection: articles.noticeSection ?? "articles §meetings",
    informationSection: articles.informationSection ?? "articles §information",
    dividendSection: articles.dividendSection ?? "articles §dividend",
    preEmptionSection: articles.preEmptionSection ?? "articles §parameters",
    minutesSection: articles.minutesSection ?? "articles §meetings",
    governorSection: articles.governorSection ?? "articles §governor",
    dragSection: sha.dragSection ?? "shareholder agreement §drag-along",
    tagSection: sha.tagSection ?? "shareholder agreement §tag-along",
  };

  return {
    value: {
      issuerId: raw.issuerId,
      event,
      articles: {
        ...articles,
        eeaListed: articles.eeaListed === true,
        electronicVotingOpen: articles.electronicVotingOpen === true,
        counselPermitsShorterConveningNotice: articles.counselPermitsShorterConveningNotice === true,
        shareForm: (articles.shareForm ?? "registered") as ShareForm,
      },
      sha,
      labels,
      holidays: raw.calendar?.holidays ?? [],
      useLiechtensteinPreset: raw.calendar?.useLiechtensteinPreset !== false,
      convention: raw.calendar?.convention ?? DEFAULT_BUSINESS_DAY_CONVENTION,
      holders,
      board,
      otherEvents,
      asOfMs,
    },
  };
}

export const INPUT_TIME_ZONE = DEFAULT_TIME_ZONE;
