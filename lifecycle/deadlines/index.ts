export { planLifecycleEvent } from "./plan.ts";
export type { PlanInput, PlanResult, Deadline, LegalBasis, SimulatedNotification } from "./types.ts";
export { easterSunday, liechtensteinHolidayDates } from "./calendar.ts";
export { DISCLAIMER, SECONDS_PER_DAY, TOOL_NAME } from "./statutory-defaults.ts";

import tool from "./schema.json" with { type: "json" };

/** MCP tool document for docs.investhub.org. Free read. The x402 calendar is not implemented. */
export const PLAN_LIFECYCLE_EVENT_TOOL = tool;
