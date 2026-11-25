import { DISCLAIMER, MAX_PERIOD_SECONDS } from "./statutory-defaults.ts";
import type { AppliedBecause, LegalBasis, PlanError, Source } from "./types.ts";

export interface PeriodRequest {
  field: string;
  configured: number | undefined;
  defaultSeconds: number;
  /** Hard floor. A shorter article value is an error the counsel flag cannot waive. */
  minimumSeconds?: number;
  /** "Within N seconds". A longer article value is an error. */
  maximumSeconds?: number;
  /**
   * The published default is also a floor unless counselPermitsShorter is set.
   * Used for PGR Art. 167(3), which the translation says yields to the articles.
   */
  displaceableDefault?: boolean;
  counselPermitsShorter?: boolean;
  allowZero?: boolean;
  defaultSource: Source;
  defaultRef: string;
  configuredSource: Source;
  configuredRef: string;
  comparedWith?: string;
  placeholderDefault?: boolean;
}

export function resolvePeriod(req: PeriodRequest): { basis: LegalBasis } | { error: PlanError } {
  const configured = req.configured;
  if (configured !== undefined) {
    if (!Number.isInteger(configured) || configured < 0 || configured > MAX_PERIOD_SECONDS) {
      return {
        error: {
          code: "period_out_of_range",
          field: req.field,
          message: `${req.field} must be an integer from ${req.allowZero ? 0 : 1} to ${MAX_PERIOD_SECONDS} seconds. The 366-day cap is GvCompanyRules.MAX_PERIOD, a software bound.`,
          articleSeconds: configured,
        },
      };
    }
    if (configured === 0 && !req.allowZero) {
      return {
        error: {
          code: "period_out_of_range",
          field: req.field,
          message: `${req.field} must be longer than zero. Omit the field to use the default.`,
          articleSeconds: 0,
        },
      };
    }
  }

  const comparedWith = req.comparedWith ?? (req.defaultSource === "statute" ? req.defaultRef : undefined);

  if (configured === undefined) {
    return {
      basis: basis({
        source: req.defaultSource,
        ref: req.defaultRef,
        comparedWith: req.placeholderDefault ? comparedWith : undefined,
        statutoryDefaultSeconds: req.defaultSeconds,
        statutoryMinimumSeconds: req.minimumSeconds,
        statutoryMaximumSeconds: req.maximumSeconds,
        appliedSeconds: req.defaultSeconds,
        appliedBecause: req.placeholderDefault ? "software_placeholder" : "statutory_default",
        placeholder: req.placeholderDefault === true,
      }),
    };
  }

  if (req.minimumSeconds !== undefined && configured < req.minimumSeconds) {
    return {
      error: {
        code: "below_statutory_minimum",
        field: req.field,
        basis: req.defaultRef,
        articleSeconds: configured,
        statutorySeconds: req.minimumSeconds,
        message:
          `${req.field} is ${configured} seconds, shorter than the statutory minimum of ${req.minimumSeconds} seconds (${req.defaultRef}). ` +
          "The plan is refused. Not legal advice. defaults to verify with Liechtenstein counsel.",
      },
    };
  }

  if (req.maximumSeconds !== undefined && configured > req.maximumSeconds) {
    return {
      error: {
        code: "above_statutory_maximum",
        field: req.field,
        basis: req.defaultRef,
        articleSeconds: configured,
        statutorySeconds: req.maximumSeconds,
        message:
          `${req.field} is ${configured} seconds, longer than the statutory maximum of ${req.maximumSeconds} seconds (${req.defaultRef}). ` +
          "A duty to act within that period cannot be planned later. Not legal advice.",
      },
    };
  }

  if (req.displaceableDefault && !req.counselPermitsShorter && configured < req.defaultSeconds) {
    return {
      error: {
        code: "below_statutory_minimum",
        field: req.field,
        basis: req.defaultRef,
        articleSeconds: configured,
        statutorySeconds: req.defaultSeconds,
        message:
          `${req.field} is ${configured} seconds, shorter than ${req.defaultSeconds} seconds (${req.defaultRef}). ` +
          "The translation says the articles may provide otherwise. This engine still refuses the shorter period unless articles.counselPermitsShorterConveningNotice is true. That flag records a counsel decision. It is not legal advice.",
      },
    };
  }

  let appliedBecause: AppliedBecause;
  if (req.displaceableDefault && req.counselPermitsShorter && configured < req.defaultSeconds) {
    appliedBecause = "counsel_permits_shorter";
  } else if (configured > req.defaultSeconds) {
    appliedBecause = "longer_than_default";
  } else if (configured === req.defaultSeconds) {
    appliedBecause = "equal_to_default";
  } else {
    appliedBecause = "configured_value";
  }

  return {
    basis: basis({
      source: req.configuredSource,
      ref: req.configuredRef,
      comparedWith,
      statutoryDefaultSeconds: req.defaultSeconds,
      statutoryMinimumSeconds: req.minimumSeconds,
      statutoryMaximumSeconds: req.maximumSeconds,
      configuredSeconds: configured,
      appliedSeconds: configured,
      appliedBecause,
      placeholder: false,
    }),
  };
}

function basis(input: Omit<LegalBasis, "note">): LegalBasis {
  return { ...input, note: noteFor(input) };
}

function noteFor(input: Omit<LegalBasis, "note">): string {
  const counsel = "Not legal advice. defaults to verify with Liechtenstein counsel.";
  switch (input.appliedBecause) {
    case "statutory_default":
      return `No article period was supplied, so the plan uses ${input.ref}. ${counsel}`;
    case "software_placeholder":
      return (
        `No period was supplied. ${input.appliedSeconds} seconds is a software placeholder` +
        `${input.comparedWith ? ` (${input.comparedWith})` : ""}, not a PGR day count. ${counsel}`
      );
    case "longer_than_default":
      return `The configured period is longer than ${input.comparedWith ?? "the default"}, so the longer period is used. ${counsel}`;
    case "equal_to_default":
      return `The configured period equals ${input.comparedWith ?? "the default"}. ${counsel}`;
    case "configured_value":
      return `The configured period is used. ${input.comparedWith ? `Compared with ${input.comparedWith}. ` : ""}${counsel}`;
    case "counsel_permits_shorter":
      return `The configured period is shorter than ${input.comparedWith ?? "the published default"}, and counselPermitsShorterConveningNotice is set. The flag is not a legal opinion. ${counsel}`;
    case "fixed_statutory_offset":
      return `${input.ref} fixes this instant. The plan does not move it for a weekend. ${counsel}`;
    default:
      return counsel;
  }
}

export const PLAN_DISCLAIMER = DISCLAIMER;
