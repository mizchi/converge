export type AuditMode = "pve" | "pvp" | "open";

export interface AuditModePolicy {
  coordinationUnit: "encounter" | "match";
  witnessStrategy: string;
  centralReplay: string;
  recommendedRetainedHeads: number;
}

export const AUDIT_MODE_POLICIES: Record<AuditMode, AuditModePolicy> = {
  pve: {
    coordinationUnit: "encounter",
    witnessStrategy: "authority-plus-participant-sample",
    centralReplay: "high-value-or-challenge",
    recommendedRetainedHeads: 4_096,
  },
  pvp: {
    coordinationUnit: "match",
    witnessStrategy: "cross-team-participant-quorum",
    centralReplay: "fork-or-dispute",
    recommendedRetainedHeads: 2_048,
  },
  open: {
    coordinationUnit: "encounter",
    witnessStrategy: "interest-group-observers",
    centralReplay: "sample-challenge-or-marketplace",
    recommendedRetainedHeads: 256,
  },
};

export function isAuditMode(value: string): value is AuditMode {
  return value === "pve" || value === "pvp" || value === "open";
}

export function isUnitKey(value: string): boolean {
  return value.length > 0 && value.length <= 128 && /^[A-Za-z0-9._:-]+$/.test(value);
}
