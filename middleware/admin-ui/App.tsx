import { useEffect, useState, type CSSProperties } from "react";

// Per-tenant Dify routing config screen. Reads/writes the middleware admin API
// (cookie-authenticated, same `admin_session` cookie as the legacy portal).
// It never receives the actual dify_api_key — only a `difyApiKeySet` boolean.

type Account = {
  slug: string;
  subdomain: string;
  name: string;
  chatwootAccountId: string;
  status: string;
  difyAppType: "agent" | "chatflow" | string | null;
  chatwootUrl: string | null;
  difyUrl: string | null; // Dify workspace ("space")
  difyAppId: string | null;
  difyAppName: string | null;
  difyApiKeySet: boolean;
};

// Deep link to the Dify app when its id is known, else the workspace ("space").
function difyAppLink(a: Account): string | null {
  if (!a.difyUrl) return null;
  const base = a.difyUrl.replace(/\/+$/, "");
  return a.difyAppId ? `${base}/app/${a.difyAppId}/configuration` : base;
}

type Draft = { appType: string; apiKey: string };

const APP_TYPES = ["chatflow", "agent"];

async function api(path: string, init?: RequestInit): Promise<Response> {
  const res = await fetch(path, {
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    ...init,
  });
  if (res.status === 401) {
    window.location.href = "/admin/login";
    throw new Error("unauthorized");
  }
  return res;
}

export function App() {
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [savingSlug, setSavingSlug] = useState<string | null>(null);
  const [toast, setToast] = useState<{ msg: string; ok: boolean } | null>(null);

  async function load() {
    setLoading(true);
    setError(null);
    try {
      const res = await api("/admin/api/accounts");
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data: Account[] = await res.json();
      setAccounts(data);
      const d: Record<string, Draft> = {};
      for (const a of data) d[a.slug] = { appType: a.difyAppType || "chatflow", apiKey: "" };
      setDrafts(d);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();
  }, []);

  function showToast(msg: string, ok: boolean) {
    setToast({ msg, ok });
    setTimeout(() => setToast(null), 4000);
  }

  async function save(slug: string) {
    const draft = drafts[slug];
    if (!draft) return;
    setSavingSlug(slug);
    try {
      const body: { difyAppType: string; difyApiKey?: string } = { difyAppType: draft.appType };
      if (draft.apiKey.trim()) body.difyApiKey = draft.apiKey.trim();
      const res = await api(`/admin/api/accounts/${encodeURIComponent(slug)}/dify`, {
        method: "PUT",
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        const j = await res.json().catch(() => ({}));
        throw new Error(j.error || `HTTP ${res.status}`);
      }
      showToast(`Salvo: ${slug}`, true);
      await load();
    } catch (e) {
      showToast(`Erro ao salvar ${slug}: ${(e as Error).message}`, false);
    } finally {
      setSavingSlug(null);
    }
  }

  return (
    <div style={S.page}>
      <header style={S.header}>
        <h1 style={S.h1}>Roteamento de Dify por conta</h1>
        <a href="/admin" style={S.back}>← Portal</a>
      </header>

      <div style={S.banner}>
        ⚠️ Keys salvas aqui gravam apenas no banco (runtime). Para reprodutibilidade,
        adicione o tenant também em <code>tenants.yaml</code> + Secret Manager
        (<code>gcp-secret:</code>) — um rebuild do zero re-semeia a partir do YAML.
      </div>

      {loading && <p>Carregando…</p>}
      {error && <p style={S.err}>Falha ao carregar: {error}</p>}

      {!loading && !error && (
        <table style={S.table}>
          <thead>
            <tr>
              <th style={S.th}>Conta</th>
              <th style={S.th}>Chatwoot acc</th>
              <th style={S.th}>Status</th>
              <th style={S.th}>Links</th>
              <th style={S.th}>Dify App Type</th>
              <th style={S.th}>Dify API Key</th>
              <th style={S.th}></th>
            </tr>
          </thead>
          <tbody>
            {accounts.map((a) => {
              const d = drafts[a.slug] || { appType: "chatflow", apiKey: "" };
              return (
                <tr key={a.slug}>
                  <td style={S.td}>
                    <strong>{a.name || a.slug}</strong>
                    <div style={S.sub}>{a.subdomain}</div>
                  </td>
                  <td style={S.td}>{a.chatwootAccountId}</td>
                  <td style={S.td}>{a.status}</td>
                  <td style={S.td}>
                    <div style={S.links}>
                      {a.chatwootUrl && (
                        <a style={S.link} href={a.chatwootUrl} target="_blank" rel="noreferrer">
                          Chatwoot ↗
                        </a>
                      )}
                      {a.difyUrl && (
                        <a style={S.link} href={a.difyUrl} target="_blank" rel="noreferrer">
                          Dify space ↗
                        </a>
                      )}
                      {difyAppLink(a) && (
                        <a style={S.link} href={difyAppLink(a)!} target="_blank" rel="noreferrer">
                          {a.difyAppName ? `App: ${a.difyAppName} ↗` : "App ↗"}
                        </a>
                      )}
                    </div>
                  </td>
                  <td style={S.td}>
                    <select
                      value={d.appType}
                      onChange={(e) =>
                        setDrafts((p) => ({ ...p, [a.slug]: { ...d, appType: e.target.value } }))
                      }
                      style={S.input}
                    >
                      {APP_TYPES.map((t) => (
                        <option key={t} value={t}>
                          {t}
                        </option>
                      ))}
                    </select>
                  </td>
                  <td style={S.td}>
                    <input
                      type="password"
                      value={d.apiKey}
                      placeholder={a.difyApiKeySet ? "•••• definida (deixe vazio p/ manter)" : "não definida"}
                      onChange={(e) =>
                        setDrafts((p) => ({ ...p, [a.slug]: { ...d, apiKey: e.target.value } }))
                      }
                      style={S.input}
                    />
                  </td>
                  <td style={S.td}>
                    <button
                      onClick={() => void save(a.slug)}
                      disabled={savingSlug === a.slug}
                      style={S.btn}
                    >
                      {savingSlug === a.slug ? "Salvando…" : "Salvar"}
                    </button>
                  </td>
                </tr>
              );
            })}
            {accounts.length === 0 && (
              <tr>
                <td style={S.td} colSpan={7}>
                  Nenhuma conta encontrada.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      )}

      {toast && (
        <div style={{ ...S.toast, background: toast.ok ? "#16a34a" : "#dc2626" }}>{toast.msg}</div>
      )}
    </div>
  );
}

const S: Record<string, CSSProperties> = {
  page: { fontFamily: "Inter, system-ui, sans-serif", maxWidth: 1000, margin: "0 auto", padding: 24, color: "#111" },
  header: { display: "flex", justifyContent: "space-between", alignItems: "center" },
  h1: { fontSize: 22, margin: 0 },
  back: { color: "#2563eb", textDecoration: "none", fontSize: 14 },
  banner: { background: "#fef3c7", border: "1px solid #fcd34d", borderRadius: 8, padding: "10px 14px", margin: "16px 0", fontSize: 13, lineHeight: 1.5 },
  table: { width: "100%", borderCollapse: "collapse", fontSize: 14 },
  th: { textAlign: "left", borderBottom: "2px solid #e5e7eb", padding: "8px 10px", fontSize: 12, textTransform: "uppercase", color: "#6b7280" },
  td: { borderBottom: "1px solid #f0f0f0", padding: "10px", verticalAlign: "middle" },
  sub: { color: "#9ca3af", fontSize: 12 },
  input: { width: "100%", padding: "6px 8px", border: "1px solid #d1d5db", borderRadius: 6, fontSize: 14, boxSizing: "border-box" },
  btn: { background: "#2563eb", color: "#fff", border: "none", borderRadius: 6, padding: "7px 14px", cursor: "pointer", fontSize: 14 },
  links: { display: "flex", flexDirection: "column", gap: 2 },
  link: { color: "#2563eb", textDecoration: "none", fontSize: 12, whiteSpace: "nowrap" },
  err: { color: "#dc2626" },
  toast: { position: "fixed", bottom: 20, right: 20, color: "#fff", padding: "10px 16px", borderRadius: 8, fontSize: 14 },
};
