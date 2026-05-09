export interface LLMAnalysis {
  root_cause: string;
  suggested_fix: string;
  severity: string;
}

export interface LokiQueryResult {
  stream: {
    service?: string;
    container?: string;
    [key: string]: string | undefined;
  };
  values: [string, string][];
}
