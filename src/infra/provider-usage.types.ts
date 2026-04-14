export type UsageWindow = {
  label: string;
  usedPercent: number;
  resetAt?: number;
};

export type ProviderUsageSnapshot = {
  provider: UsageProviderId;
  displayName: string;
  windows: UsageWindow[];
  plan?: string;
  error?: string;
  /** Auth profile identifier (e.g. `openai-codex:daishenyang`). Empty when the
   * provider does not support multi-profile auth. Used by clients to
   * disambiguate entries that share the same provider id. */
  profileId?: string;
  /** Optional human-readable account label (e.g. email) for display. */
  accountId?: string;
};

export type UsageSummary = {
  updatedAt: number;
  providers: ProviderUsageSnapshot[];
};

export type UsageProviderId =
  | "anthropic"
  | "github-copilot"
  | "google-gemini-cli"
  | "minimax"
  | "openai-codex"
  | "xiaomi"
  | "zai";
