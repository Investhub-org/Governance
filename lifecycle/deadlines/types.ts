export type Source = "statute" | "articles" | "sha";

export type EventKind = "agm" | "egm" | "dividend" | "capital_increase" | "drag_along" | "tag_along";

export type Audience = "all_holders_at_record_date" | "affected_class" | "board";

export type ShareForm = "registered" | "bearer";

export type Convention = "none" | "notice_earlier_window_later";

export type AppliedBecause =
  | "statutory_default"
  | "software_placeholder"
  | "equal_to_default"
  | "longer_than_default"
  | "configured_value"
  | "counsel_permits_shorter"
  | "fixed_statutory_offset";

export type Clock = "civil_vaduz" | "unix";

export type Shift = "latest_by" | "window_end" | "anchor" | "fixed" | "unix";

export type BusinessDayAdjustment = "none" | "previous_business_day" | "next_business_day";

export interface ArticlesConfig {
  agmNoticeSeconds?: number;
  egmNoticeSeconds?: number;
  preEmptionWindowSeconds?: number;
  responseWindowSeconds?: number;
  informationLeadSeconds?: number;
  minutesPublicationSeconds?: number;
  dividendRecordLeadSeconds?: number;
  dividendClaimWindowSeconds?: number;
  votingWindowSeconds?: number;
  votingDelaySeconds?: number;
  votingPeriodSeconds?: number;
  recordLeadSeconds?: number;
  eeaListed?: boolean;
  electronicVotingOpen?: boolean;
  counselPermitsShorterConveningNotice?: boolean;
  shareForm?: ShareForm;
  noticeSection?: string;
  informationSection?: string;
  dividendSection?: string;
  preEmptionSection?: string;
  minutesSection?: string;
  governorSection?: string;
}

export interface ShaConfig {
  dragResponseSeconds?: number;
  tagResponseSeconds?: number;
  dragSection?: string;
  tagSection?: string;
}

export interface CalendarConfig {
  timeZone?: string;
  holidays?: string[];
  useLiechtensteinPreset?: boolean;
  convention?: Convention;
}

export interface Holder {
  address: string;
  classId?: string;
}

export interface LifecycleEventInput {
  id?: string;
  kind: EventKind;
  at: string;
  classId?: string;
  financialYearEnd?: string;
}

export interface PlanInput {
  issuerId: string;
  event: LifecycleEventInput;
  articles?: ArticlesConfig;
  sha?: ShaConfig;
  calendar?: CalendarConfig;
  holders?: Holder[];
  board?: string[];
  otherEvents?: LifecycleEventInput[];
  asOf?: string;
}

export interface LegalBasis {
  source: Source;
  ref: string;
  comparedWith?: string;
  statutoryDefaultSeconds?: number;
  statutoryMinimumSeconds?: number;
  statutoryMaximumSeconds?: number;
  configuredSeconds?: number;
  appliedSeconds: number;
  appliedBecause: AppliedBecause;
  placeholder: boolean;
  note: string;
}

export interface OnChainHint {
  contract: string;
  parameter: string;
}

export interface Deadline {
  id: string;
  at: string;
  atMs: number;
  action: string;
  audiences: Audience[];
  templateKey: string;
  latestSendAt: string;
  legalBasis: LegalBasis;
  businessDayAdjustment: BusinessDayAdjustment;
  clock: Clock;
  onChain: OnChainHint | null;
  due: "past" | "upcoming" | "unspecified";
  rank: number;
}

export interface SimulatedNotification {
  deadlineId: string;
  templateKey: string;
  audience: Audience;
  latestSendAt: string;
  signed: false;
  transmitted: false;
  channel: "simulated";
  recipientTiming: "register_not_yet_fixed" | "caller_supplied_snapshot";
  recipients: Array<{ address: string; role: "holder" | "board"; classId?: string }>;
  payload: {
    templateKey: string;
    issuerId: string;
    eventKind: EventKind;
    eventId: string;
    deadlineId: string;
    at: string;
    legalBasisRef: string;
    legalBasisSource: Source;
    signed: false;
    transmitted: false;
  };
}

export interface PlanError {
  code:
    | "invalid_input"
    | "below_statutory_minimum"
    | "above_statutory_maximum"
    | "conflicts_with_statute"
    | "outside_statutory_outer_bound"
    | "period_out_of_range"
    | "duplicate_event_id"
    | "no_business_day";
  field: string;
  message: string;
  basis?: string;
  articleSeconds?: number;
  statutorySeconds?: number;
}

export interface PlanWarning {
  code:
    | "notice_after_information_availability"
    | "anchor_not_business_day"
    | "window_ends_on_non_business_day"
    | "fixed_date_not_business_day"
    | "shorter_than_published_statutory_default"
    | "no_affected_holders"
    | "sha_window_not_a_statute";
  message: string;
}

export interface Overlap {
  eventId: string;
  eventKind: EventKind;
  otherEventId: string;
  otherKind: EventKind;
  start: string;
  end: string;
  startMs: number;
  endMs: number;
}

export interface PremiumMarker {
  name: "governance.plan_lifecycle_calendar";
  tier: "x402";
  implemented: false;
  note: string;
}

export interface PlanResult {
  ok: boolean;
  tool: "governance.plan_lifecycle_event";
  tier: "free";
  signed: false;
  transmitted: false;
  disclaimer: string;
  issuerId: string | null;
  eventId: string | null;
  timeZone: "Europe/Vaduz";
  deadlines: Deadline[];
  notifications: SimulatedNotification[];
  errors: PlanError[];
  warnings: PlanWarning[];
  overlaps: Overlap[];
  premium: PremiumMarker;
  planId: string;
}

export interface Labels {
  noticeSection: string;
  informationSection: string;
  dividendSection: string;
  preEmptionSection: string;
  minutesSection: string;
  governorSection: string;
  dragSection: string;
  tagSection: string;
}

export interface NormalizedEvent {
  id: string;
  kind: EventKind;
  atMs: number;
  classId?: string;
  financialYearEndMs?: number;
}

export interface NormalizedInput {
  issuerId: string;
  event: NormalizedEvent;
  articles: ArticlesConfig & {
    eeaListed: boolean;
    electronicVotingOpen: boolean;
    counselPermitsShorterConveningNotice: boolean;
    shareForm: ShareForm;
  };
  sha: ShaConfig;
  labels: Labels;
  holidays: string[];
  useLiechtensteinPreset: boolean;
  convention: Convention;
  holders: Holder[];
  board: string[];
  otherEvents: NormalizedEvent[];
  asOfMs?: number;
}
