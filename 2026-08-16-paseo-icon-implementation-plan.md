# Paseo Icon — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standalone macOS menu-bar app that shows whether any Paseo agent needs you, across every configured host, and jumps you to that agent in one click.

**Architecture:** One Electron main process with no `BrowserWindow` ever created. One `DaemonClient` per configured host feeds a replicated `AgentStore`; a pure function derives icon, count, and menu from the store; an Electron tray presenter applies it. Everything that can be gotten wrong is pure TypeScript tested without Electron.

**Tech Stack:** TypeScript 5.9 (ESM), Electron 41.2.0, vitest 4, zod 4, `@getpaseo/client@0.4.0`, `@getpaseo/protocol@0.4.0`, `@getpaseo/server@0.4.0` (tests only), `sharp` (icon generation only), electron-builder 26.

**Spec:** `2026-08-16-standalone-menubar-app-design.md` (same directory)

## Global Constraints

Every task's requirements implicitly include this section.

- **Never create a `BrowserWindow`.** The app is main-process only. A preferences window is explicitly deferred.
- **Pin the SDK exactly**: `@getpaseo/client@0.4.0`, `@getpaseo/protocol@0.4.0`. No `^`. The daemon guarantees backward compatibility for old clients; drifting the client forward voids that reasoning.
- **`@getpaseo/client/internal/daemon-client` is the entry point, not `createPaseoClient`.** The public wrapper does not expose `serverId`, and deep links require it. `DaemonClient.getLastServerInfoMessage()` does. Confine all SDK use to `src/daemon/host-connection.ts` so the internal surface lives in one file.
- **Node ≥ 22 / Electron 41.** The code relies on a global `WebSocket`, which is how the SDK's default factory works without a `ws` dependency. Password auth rides the `paseo.bearer.<password>` subprotocol, so header-less global WebSocket is sufficient.
- **ESM everywhere.** `"type": "module"`, TypeScript `module: nodenext`. Electron 41 supports ESM main.
- **`config.json` is written with mode `0600`.** It holds TCP passwords and relay keys.
- **No silent caps.** Any truncated list renders an explicit overflow row.
- **Attention outranks working** for icon priority. This is deliberately the opposite of the Paseo app's favicon.
- **Agents with `archivedAt` set are excluded everywhere**, including counts.
- **A disconnected host's agents leave the counts**, so the icon never reflects unvouched data.
- **License AGPL-3.0-or-later.** Every source file gets no header; the LICENSE file and `package.json` field carry it.
- **On this Mac, install with `SHARP_IGNORE_GLOBAL_LIBVIPS=1`.** A Homebrew libvips makes `sharp` skip its prebuilt binary and fail under node-gyp.

---

### Task 1: Scaffold the project and land the agent store

**Files:**
- Create: `package.json`, `tsconfig.json`, `vitest.config.ts`, `.gitignore`, `LICENSE`
- Create: `src/daemon/agent-store.ts`
- Test: `src/daemon/agent-store.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `HostStatus`, `HostAgents`, `AgentStore` with `setHost(hostId, label)`, `removeHost(hostId)`, `setStatus(hostId, status)`, `setServerId(hostId, serverId)`, `seed(hostId, agents)`, `applyUpdate(hostId, update)`, `snapshot(): HostAgents[]`, `subscribe(listener): () => void`.

- [ ] **Step 1: Initialize the repo and write `package.json`**

```bash
cd ~/Development/paseo-icon && git init
```

```json
{
  "name": "paseo-icon",
  "productName": "Paseo Icon",
  "version": "0.1.0",
  "description": "Menu-bar indicator for Paseo agents",
  "license": "AGPL-3.0-or-later",
  "type": "module",
  "main": "dist/main.js",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "test": "vitest run",
    "icons": "node scripts/make-icons.mjs",
    "start": "npm run build && electron .",
    "dist": "npm run build && npm run icons && electron-builder"
  },
  "dependencies": {
    "@getpaseo/client": "0.4.0",
    "@getpaseo/protocol": "0.4.0",
    "zod": "^4.4.3"
  },
  "devDependencies": {
    "@getpaseo/server": "0.4.0",
    "@types/node": "^24.6.0",
    "electron": "41.2.0",
    "electron-builder": "^26.8.1",
    "pino": "^9.5.0",
    "sharp": "^0.34.0",
    "typescript": "^5.9.3",
    "vitest": "^4.1.6"
  }
}
```

- [ ] **Step 2: Write `tsconfig.json`, `vitest.config.ts`, `.gitignore`, and `LICENSE`**

`tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2023",
    "module": "nodenext",
    "moduleResolution": "nodenext",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "skipLibCheck": true,
    "sourceMap": true
  },
  "include": ["src/**/*.ts"],
  "exclude": ["src/**/*.test.ts"]
}
```

`vitest.config.ts`:

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
    testTimeout: 30_000,
  },
});
```

`.gitignore`:

```
node_modules/
dist/
release/
assets/generated/
```

`LICENSE`: the full GNU AGPL v3 text, fetched verbatim from https://www.gnu.org/licenses/agpl-3.0.txt.

- [ ] **Step 3: Install dependencies**

```bash
cd ~/Development/paseo-icon && SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install
```

Expected: completes without a node-gyp build of sharp. If sharp still builds from source, the env var was dropped — rerun with it set.

- [ ] **Step 4: Write the failing test**

`src/daemon/agent-store.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import type { AgentSnapshotPayload } from "@getpaseo/protocol/messages";
import { AgentStore } from "./agent-store.js";

function agent(id: string, overrides: Partial<AgentSnapshotPayload> = {}): AgentSnapshotPayload {
  return {
    id,
    provider: "claude",
    cwd: `/work/${id}`,
    model: null,
    createdAt: "2026-08-16T00:00:00.000Z",
    updatedAt: "2026-08-16T00:00:00.000Z",
    lastUserMessageAt: null,
    status: "idle",
    capabilities: {},
    currentModeId: null,
    availableModes: [],
    pendingPermissions: [],
    persistence: null,
    title: id,
    labels: {},
    ...overrides,
  } as AgentSnapshotPayload;
}

describe("AgentStore", () => {
  it("seeds a host and reports its agents", () => {
    const store = new AgentStore();
    store.setHost("h1", "laptop");
    store.seed("h1", [agent("a"), agent("b")]);

    const [host] = store.snapshot();
    expect(host?.label).toBe("laptop");
    expect(host?.agents.map((a) => a.id)).toEqual(["a", "b"]);
  });

  it("applies an upsert as a full replacement", () => {
    const store = new AgentStore();
    store.setHost("h1", "laptop");
    store.seed("h1", [agent("a", { status: "idle" })]);
    store.applyUpdate("h1", { kind: "upsert", agent: agent("a", { status: "running" }) });

    expect(store.snapshot()[0]?.agents[0]?.status).toBe("running");
  });

  it("applies a remove", () => {
    const store = new AgentStore();
    store.setHost("h1", "laptop");
    store.seed("h1", [agent("a"), agent("b")]);
    store.applyUpdate("h1", { kind: "remove", agentId: "a" });

    expect(store.snapshot()[0]?.agents.map((a) => a.id)).toEqual(["b"]);
  });

  it("re-seeding replaces wholesale so a subscription gap cannot strand an agent", () => {
    const store = new AgentStore();
    store.setHost("h1", "laptop");
    store.seed("h1", [agent("a"), agent("b")]);
    store.seed("h1", [agent("b")]);

    expect(store.snapshot()[0]?.agents.map((a) => a.id)).toEqual(["b"]);
  });

  it("tracks status and serverId per host", () => {
    const store = new AgentStore();
    store.setHost("h1", "laptop");
    expect(store.snapshot()[0]?.status).toBe("connecting");

    store.setStatus("h1", "connected");
    store.setServerId("h1", "srv-1");

    expect(store.snapshot()[0]?.status).toBe("connected");
    expect(store.snapshot()[0]?.serverId).toBe("srv-1");
  });

  it("removing a host drops it entirely", () => {
    const store = new AgentStore();
    store.setHost("h1", "laptop");
    store.removeHost("h1");
    expect(store.snapshot()).toEqual([]);
  });

  it("notifies subscribers on change and stops after unsubscribe", () => {
    const store = new AgentStore();
    const listener = vi.fn();
    const unsubscribe = store.subscribe(listener);

    store.setHost("h1", "laptop");
    expect(listener).toHaveBeenCalledTimes(1);

    unsubscribe();
    store.setStatus("h1", "connected");
    expect(listener).toHaveBeenCalledTimes(1);
  });

  it("ignores updates for unknown hosts instead of throwing", () => {
    const store = new AgentStore();
    expect(() => store.applyUpdate("nope", { kind: "remove", agentId: "a" })).not.toThrow();
    expect(store.snapshot()).toEqual([]);
  });
});
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `npx vitest run src/daemon/agent-store.test.ts`
Expected: FAIL — cannot resolve `./agent-store.js`.

- [ ] **Step 6: Implement `src/daemon/agent-store.ts`**

```ts
import type { AgentSnapshotPayload } from "@getpaseo/protocol/messages";

export type HostStatus = "connecting" | "connected" | "disconnected" | "unauthorized";

/** The `agent_update` payload shape, narrowed to what the store applies. */
export type AgentUpdate =
  | { kind: "upsert"; agent: AgentSnapshotPayload }
  | { kind: "remove"; agentId: string };

export interface HostAgents {
  hostId: string;
  label: string;
  status: HostStatus;
  serverId: string | null;
  agents: AgentSnapshotPayload[];
}

interface HostEntryState {
  label: string;
  status: HostStatus;
  serverId: string | null;
  agents: Map<string, AgentSnapshotPayload>;
}

export class AgentStore {
  private readonly hosts = new Map<string, HostEntryState>();
  private readonly listeners = new Set<() => void>();

  setHost(hostId: string, label: string): void {
    const existing = this.hosts.get(hostId);
    if (existing) {
      existing.label = label;
    } else {
      this.hosts.set(hostId, {
        label,
        status: "connecting",
        serverId: null,
        agents: new Map(),
      });
    }
    this.emit();
  }

  removeHost(hostId: string): void {
    if (this.hosts.delete(hostId)) this.emit();
  }

  setStatus(hostId: string, status: HostStatus): void {
    const host = this.hosts.get(hostId);
    if (!host || host.status === status) return;
    host.status = status;
    this.emit();
  }

  setServerId(hostId: string, serverId: string): void {
    const host = this.hosts.get(hostId);
    if (!host || host.serverId === serverId) return;
    host.serverId = serverId;
    this.emit();
  }

  /** Replaces the host's agents wholesale. Called on connect and on every reconnect. */
  seed(hostId: string, agents: AgentSnapshotPayload[]): void {
    const host = this.hosts.get(hostId);
    if (!host) return;
    host.agents = new Map(agents.map((entry) => [entry.id, entry]));
    this.emit();
  }

  applyUpdate(hostId: string, update: AgentUpdate): void {
    const host = this.hosts.get(hostId);
    if (!host) return;
    if (update.kind === "upsert") {
      host.agents.set(update.agent.id, update.agent);
    } else {
      if (!host.agents.delete(update.agentId)) return;
    }
    this.emit();
  }

  snapshot(): HostAgents[] {
    return [...this.hosts.entries()].map(([hostId, host]) => ({
      hostId,
      label: host.label,
      status: host.status,
      serverId: host.serverId,
      agents: [...host.agents.values()],
    }));
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private emit(): void {
    for (const listener of this.listeners) listener();
  }
}
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `npx vitest run src/daemon/agent-store.test.ts`
Expected: PASS, 8 tests.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: scaffold project and add replicated agent store"
```

---

### Task 2: Derive the tray view model

**Files:**
- Create: `src/tray/view-model.ts`
- Test: `src/tray/view-model.test.ts`

**Interfaces:**
- Consumes: `HostAgents`, `HostStatus` from `src/daemon/agent-store.ts`.
- Produces: `TrayIconState` (`"idle" | "working" | "attention"`), `TrayAgentRow`, `TrayMenuSection`, `TrayViewModel`, and `deriveTrayViewModel(hosts: HostAgents[]): TrayViewModel`.

- [ ] **Step 1: Write the failing test**

`src/tray/view-model.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import type { AgentSnapshotPayload } from "@getpaseo/protocol/messages";
import type { HostAgents } from "../daemon/agent-store.js";
import { deriveTrayViewModel } from "./view-model.js";

function agent(id: string, overrides: Partial<AgentSnapshotPayload> = {}): AgentSnapshotPayload {
  return {
    id,
    provider: "claude",
    cwd: `/work/${id}`,
    model: null,
    createdAt: "2026-08-16T00:00:00.000Z",
    updatedAt: "2026-08-16T00:00:00.000Z",
    lastUserMessageAt: null,
    status: "idle",
    capabilities: {},
    currentModeId: null,
    availableModes: [],
    pendingPermissions: [],
    persistence: null,
    title: id,
    labels: {},
    ...overrides,
  } as AgentSnapshotPayload;
}

function host(agents: AgentSnapshotPayload[], overrides: Partial<HostAgents> = {}): HostAgents {
  return {
    hostId: "h1",
    label: "laptop",
    status: "connected",
    serverId: "srv-1",
    agents,
    ...overrides,
  };
}

describe("deriveTrayViewModel", () => {
  it("is idle with no agents", () => {
    const model = deriveTrayViewModel([host([])]);
    expect(model.icon).toBe("idle");
    expect(model.count).toBe(0);
  });

  it("is working when an agent is running", () => {
    const model = deriveTrayViewModel([host([agent("a", { status: "running" })])]);
    expect(model.icon).toBe("working");
    expect(model.count).toBe(0);
  });

  it("treats initializing as working", () => {
    const model = deriveTrayViewModel([host([agent("a", { status: "initializing" })])]);
    expect(model.icon).toBe("working");
  });

  it("lets attention outrank running", () => {
    const model = deriveTrayViewModel([
      host([
        agent("a", { status: "running" }),
        agent("b", { requiresAttention: true, attentionReason: "finished" }),
      ]),
    ]);
    expect(model.icon).toBe("attention");
    expect(model.count).toBe(1);
  });

  it("counts every attention reason in one number", () => {
    const model = deriveTrayViewModel([
      host([
        agent("a", { requiresAttention: true, attentionReason: "finished" }),
        agent("b", { requiresAttention: true, attentionReason: "permission" }),
        agent("c", { requiresAttention: true, attentionReason: "error" }),
      ]),
    ]);
    expect(model.count).toBe(3);
  });

  it("excludes archived agents from counts and rows", () => {
    const model = deriveTrayViewModel([
      host([agent("a", { requiresAttention: true, archivedAt: "2026-08-16T00:00:00.000Z" })]),
    ]);
    expect(model.icon).toBe("idle");
    expect(model.count).toBe(0);
    expect(model.sections).toEqual([]);
  });

  it("excludes a disconnected host's agents from counts", () => {
    const model = deriveTrayViewModel([
      host([agent("a", { requiresAttention: true })], { status: "disconnected" }),
    ]);
    expect(model.icon).toBe("idle");
    expect(model.count).toBe(0);
  });

  it("groups by state with attention first", () => {
    const model = deriveTrayViewModel([
      host([
        agent("idle-one"),
        agent("run", { status: "running" }),
        agent("att", { requiresAttention: true, attentionReason: "permission" }),
      ]),
    ]);
    expect(model.sections.map((s) => s.kind)).toEqual(["attention", "working", "idle"]);
    expect(model.sections[0]?.rows[0]?.agentId).toBe("att");
  });

  it("omits the host label with a single host and includes it with two", () => {
    const single = deriveTrayViewModel([host([agent("a", { requiresAttention: true })])]);
    expect(single.sections[0]?.rows[0]?.hostLabel).toBeNull();

    const multiple = deriveTrayViewModel([
      host([agent("a", { requiresAttention: true })]),
      host([], { hostId: "h2", label: "studio", serverId: "srv-2" }),
    ]);
    expect(multiple.sections[0]?.rows[0]?.hostLabel).toBe("laptop");
  });

  it("falls back to the cwd basename when title is null", () => {
    const model = deriveTrayViewModel([
      host([agent("a", { title: null, cwd: "/work/api-server", requiresAttention: true })]),
    ]);
    expect(model.sections[0]?.rows[0]?.label).toBe("api-server");
  });

  it("caps attention rows at 15 and reports the overflow", () => {
    const many = Array.from({ length: 18 }, (_, index) =>
      agent(`a${index}`, { requiresAttention: true, attentionReason: "finished" }),
    );
    const model = deriveTrayViewModel([host(many)]);
    const attention = model.sections.find((s) => s.kind === "attention");
    expect(attention?.rows).toHaveLength(15);
    expect(attention?.overflow).toBe(3);
  });

  it("reports host connection state for the status footer", () => {
    const model = deriveTrayViewModel([
      host([], { status: "connected" }),
      host([], { hostId: "h2", label: "studio", status: "disconnected", serverId: null }),
    ]);
    expect(model.hostStatuses).toEqual([
      { hostId: "h1", label: "laptop", status: "connected" },
      { hostId: "h2", label: "studio", status: "disconnected" },
    ]);
  });

  it("carries serverId on rows so a click can build a deep link", () => {
    const model = deriveTrayViewModel([host([agent("a", { requiresAttention: true })])]);
    expect(model.sections[0]?.rows[0]).toMatchObject({ serverId: "srv-1", agentId: "a" });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx vitest run src/tray/view-model.test.ts`
Expected: FAIL — cannot resolve `./view-model.js`.

- [ ] **Step 3: Implement `src/tray/view-model.ts`**

```ts
import type { AgentSnapshotPayload } from "@getpaseo/protocol/messages";
import type { HostAgents, HostStatus } from "../daemon/agent-store.js";

export type TrayIconState = "idle" | "working" | "attention";
export type TraySectionKind = "attention" | "working" | "idle";

/** Rows in the attention section cap here; the rest become an explicit overflow row. */
const ATTENTION_ROW_CAP = 15;

export interface TrayAgentRow {
  hostId: string;
  serverId: string | null;
  agentId: string;
  label: string;
  /** `finished`, `permission`, or `error`; null outside the attention section. */
  detail: string | null;
  /** Null when only one host is configured. */
  hostLabel: string | null;
}

export interface TrayMenuSection {
  kind: TraySectionKind;
  rows: TrayAgentRow[];
  /** Rows dropped by the cap. Always rendered, never silent. */
  overflow: number;
}

export interface TrayHostStatus {
  hostId: string;
  label: string;
  status: HostStatus;
}

export interface TrayViewModel {
  icon: TrayIconState;
  count: number;
  sections: TrayMenuSection[];
  hostStatuses: TrayHostStatus[];
}

function isVisible(agent: AgentSnapshotPayload): boolean {
  return !agent.archivedAt;
}

function needsAttention(agent: AgentSnapshotPayload): boolean {
  return agent.requiresAttention === true;
}

function isWorking(agent: AgentSnapshotPayload): boolean {
  return agent.status === "running" || agent.status === "initializing";
}

function rowLabel(agent: AgentSnapshotPayload): string {
  const title = agent.title?.trim();
  if (title) return title;
  const segments = agent.cwd.split("/").filter(Boolean);
  return segments[segments.length - 1] ?? agent.cwd;
}

function buildSection(
  kind: TraySectionKind,
  rows: TrayAgentRow[],
  cap: number | null,
): TrayMenuSection | null {
  if (rows.length === 0) return null;
  if (cap === null || rows.length <= cap) return { kind, rows, overflow: 0 };
  return { kind, rows: rows.slice(0, cap), overflow: rows.length - cap };
}

export function deriveTrayViewModel(hosts: HostAgents[]): TrayViewModel {
  const showHostLabel = hosts.length > 1;

  // A disconnected host's agents are data we cannot vouch for, so they never
  // reach the icon, the count, or the menu.
  const live = hosts.filter((host) => host.status === "connected");

  const attention: TrayAgentRow[] = [];
  const working: TrayAgentRow[] = [];
  const idle: TrayAgentRow[] = [];

  for (const host of live) {
    for (const agent of host.agents) {
      if (!isVisible(agent)) continue;
      const base = {
        hostId: host.hostId,
        serverId: host.serverId,
        agentId: agent.id,
        label: rowLabel(agent),
        hostLabel: showHostLabel ? host.label : null,
      };
      if (needsAttention(agent)) {
        attention.push({ ...base, detail: agent.attentionReason ?? null });
      } else if (isWorking(agent)) {
        working.push({ ...base, detail: null });
      } else {
        idle.push({ ...base, detail: null });
      }
    }
  }

  const sections = [
    buildSection("attention", attention, ATTENTION_ROW_CAP),
    buildSection("working", working, null),
    buildSection("idle", idle, null),
  ].filter((section): section is TrayMenuSection => section !== null);

  const icon: TrayIconState =
    attention.length > 0 ? "attention" : working.length > 0 ? "working" : "idle";

  return {
    icon,
    count: attention.length,
    sections,
    hostStatuses: hosts.map((host) => ({
      hostId: host.hostId,
      label: host.label,
      status: host.status,
    })),
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx vitest run src/tray/view-model.test.ts`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: derive tray icon, count, and menu sections from store state"
```

---

### Task 3: Config file with restrictive permissions

**Files:**
- Create: `src/config/host-config.ts`
- Test: `src/config/host-config.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `HostEntry`, `HostEntrySchema`, `AppConfig`, `AppConfigSchema`, `configPath(dir)`, `loadConfig(dir): Promise<AppConfig>`, `saveConfig(dir, config): Promise<void>`, `watchConfig(dir, onChange): () => void`.

A `HostEntry` is a discriminated union on `type`, built from the published schemas rather than parallel ones. `directTcp` is `DirectTcpHostConnectionSchema` from `@getpaseo/protocol/host-connection-schema` extended with a `label`. `relay` wraps a `ConnectionOffer` verbatim under an `offer` key, so a pairing link is stored exactly as it was issued.

- [ ] **Step 1: Write the failing test**

`src/config/host-config.test.ts`:

```ts
import { afterEach, describe, expect, it } from "vitest";
import { mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { configPath, loadConfig, saveConfig, watchConfig } from "./host-config.js";

const dirs: string[] = [];

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "paseo-icon-"));
  dirs.push(dir);
  return dir;
}

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

describe("host config", () => {
  it("returns an empty host list when the file does not exist", async () => {
    const dir = await tempDir();
    expect(await loadConfig(dir)).toEqual({ version: 1, hosts: [] });
  });

  it("round-trips a direct host", async () => {
    const dir = await tempDir();
    const config = {
      version: 1 as const,
      hosts: [
        {
          id: "h1",
          label: "laptop",
          type: "directTcp" as const,
          endpoint: "localhost:6767",
          useTls: false,
          password: "hunter2",
        },
      ],
    };
    await saveConfig(dir, config);
    expect(await loadConfig(dir)).toEqual(config);
  });

  it("round-trips a relay host with the offer stored verbatim", async () => {
    const dir = await tempDir();
    const config = {
      version: 1 as const,
      hosts: [
        {
          id: "h2",
          label: "studio",
          type: "relay" as const,
          offer: {
            v: 2 as const,
            serverId: "srv-2",
            daemonPublicKeyB64: "AAAA",
            relay: { endpoint: "relay.paseo.sh:443", useTls: true },
          },
        },
      ],
    };
    await saveConfig(dir, config);
    expect(await loadConfig(dir)).toEqual(config);
  });

  it("writes the file 0600 because it holds passwords and relay keys", async () => {
    const dir = await tempDir();
    await saveConfig(dir, { version: 1, hosts: [] });
    const info = await stat(configPath(dir));
    expect(info.mode & 0o777).toBe(0o600);
  });

  it("notifies once when the file changes, debounced", async () => {
    const dir = await tempDir();
    await saveConfig(dir, { version: 1, hosts: [] });

    let calls = 0;
    const stop = watchConfig(dir, () => {
      calls += 1;
    });

    await saveConfig(dir, { version: 1, hosts: [] });
    await saveConfig(dir, { version: 1, hosts: [] });
    await new Promise((resolve) => setTimeout(resolve, 500));
    stop();

    expect(calls).toBe(1);
  });

  it("throws on malformed JSON rather than silently resetting", async () => {
    const dir = await tempDir();
    await writeFile(configPath(dir), "{ not json", "utf8");
    await expect(loadConfig(dir)).rejects.toThrow(/config/i);
  });

  it("throws on a schema violation rather than dropping the bad host", async () => {
    const dir = await tempDir();
    await writeFile(
      configPath(dir),
      JSON.stringify({ version: 1, hosts: [{ id: "h1", type: "directTcp" }] }),
      "utf8",
    );
    await expect(loadConfig(dir)).rejects.toThrow(/config/i);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx vitest run src/config/host-config.test.ts`
Expected: FAIL — cannot resolve `./host-config.js`.

- [ ] **Step 3: Implement `src/config/host-config.ts`**

```ts
import { readFile, writeFile, chmod } from "node:fs/promises";
import { watch } from "node:fs";
import path from "node:path";
import { z } from "zod";
import { DirectTcpHostConnectionSchema } from "@getpaseo/protocol/host-connection-schema";
import { ConnectionOfferSchema } from "@getpaseo/protocol/connection-offer";

// Both host shapes come from the published schemas rather than parallel
// redefinitions, so a protocol change surfaces as a type error here.
const DirectHostSchema = DirectTcpHostConnectionSchema.extend({
  label: z.string().min(1),
});

const RelayHostSchema = z.object({
  id: z.string().min(1),
  type: z.literal("relay"),
  label: z.string().min(1),
  /** The pairing offer, stored exactly as `paseo daemon pair` issued it. */
  offer: ConnectionOfferSchema,
});

export const HostEntrySchema = z.discriminatedUnion("type", [DirectHostSchema, RelayHostSchema]);
export type HostEntry = z.infer<typeof HostEntrySchema>;

export const AppConfigSchema = z.object({
  version: z.literal(1),
  hosts: z.array(HostEntrySchema),
});
export type AppConfig = z.infer<typeof AppConfigSchema>;

export function configPath(dir: string): string {
  return path.join(dir, "config.json");
}

export async function loadConfig(dir: string): Promise<AppConfig> {
  let raw: string;
  try {
    raw = await readFile(configPath(dir), "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return { version: 1, hosts: [] };
    }
    throw error;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`Invalid config at ${configPath(dir)}: not valid JSON`, { cause: error });
  }

  const result = AppConfigSchema.safeParse(parsed);
  if (!result.success) {
    throw new Error(`Invalid config at ${configPath(dir)}: ${result.error.message}`);
  }
  return result.data;
}

export async function saveConfig(dir: string, config: AppConfig): Promise<void> {
  const target = configPath(dir);
  // Passwords and relay keys live here, so the file is owner-only.
  await writeFile(target, `${JSON.stringify(config, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
  await chmod(target, 0o600);
}

const WATCH_DEBOUNCE_MS = 250;

/**
 * Calls `onChange` after the config file settles. Editors and our own writes
 * both produce bursts of events, so a debounce is required, not a nicety.
 */
export function watchConfig(dir: string, onChange: () => void): () => void {
  let timer: NodeJS.Timeout | null = null;
  const watcher = watch(dir, (_event, filename) => {
    if (filename && filename !== "config.json") return;
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      onChange();
    }, WATCH_DEBOUNCE_MS);
  });

  return () => {
    if (timer) clearTimeout(timer);
    watcher.close();
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx vitest run src/config/host-config.test.ts`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: load and save host config with owner-only permissions"
```

---

### Task 4: Turn a pairing URL into a host entry

**Files:**
- Create: `src/config/pairing.ts`
- Test: `src/config/pairing.test.ts`

**Interfaces:**
- Consumes: `HostEntry` from `src/config/host-config.ts`.
- Produces: `hostEntryFromPairingUrl(input: string, options: { id: string; label?: string }): HostEntry | null`. Returns null when the input carries no `#offer=` fragment; throws when the fragment exists but is malformed.

- [ ] **Step 1: Write the failing test**

`src/config/pairing.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { hostEntryFromPairingUrl } from "./pairing.js";

function offerUrl(payload: unknown): string {
  const encoded = Buffer.from(JSON.stringify(payload), "utf8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  return `https://app.paseo.sh/#offer=${encoded}`;
}

const validOffer = {
  v: 2,
  serverId: "srv-2",
  daemonPublicKeyB64: "AAAA",
  relay: { endpoint: "relay.paseo.sh:443", useTls: true },
};

describe("hostEntryFromPairingUrl", () => {
  it("builds a relay host entry from a pairing URL", () => {
    expect(hostEntryFromPairingUrl(offerUrl(validOffer), { id: "h2", label: "studio" })).toEqual({
      id: "h2",
      type: "relay",
      label: "studio",
      offer: {
        v: 2,
        serverId: "srv-2",
        daemonPublicKeyB64: "AAAA",
        relay: { endpoint: "relay.paseo.sh:443", useTls: true },
      },
    });
  });

  it("defaults the label to the serverId", () => {
    const entry = hostEntryFromPairingUrl(offerUrl(validOffer), { id: "h2" });
    expect(entry?.label).toBe("srv-2");
  });

  it("stores the offer verbatim, leaving an omitted useTls absent", () => {
    const entry = hostEntryFromPairingUrl(
      offerUrl({ ...validOffer, relay: { endpoint: "relay.paseo.sh:443" } }),
      { id: "h2" },
    );
    expect(entry).toMatchObject({ offer: { relay: { endpoint: "relay.paseo.sh:443" } } });
    expect(entry?.type === "relay" && entry.offer.relay.useTls).toBeUndefined();
  });

  it("returns null when the text has no offer fragment", () => {
    expect(hostEntryFromPairingUrl("https://app.paseo.sh/", { id: "h2" })).toBeNull();
    expect(hostEntryFromPairingUrl("just some clipboard text", { id: "h2" })).toBeNull();
  });

  it("throws when the fragment exists but is malformed", () => {
    expect(() => hostEntryFromPairingUrl("https://app.paseo.sh/#offer=zzzz", { id: "h2" })).toThrow();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx vitest run src/config/pairing.test.ts`
Expected: FAIL — cannot resolve `./pairing.js`.

- [ ] **Step 3: Implement `src/config/pairing.ts`**

```ts
import { parseConnectionOfferFromUrl } from "@getpaseo/protocol/connection-offer";
import type { HostEntry } from "./host-config.js";

/**
 * Parses the URL printed by `paseo daemon pair`.
 *
 * Returns null when the input is not a pairing URL at all, which is the common
 * case for arbitrary clipboard contents. Throws when it looks like one but the
 * payload does not validate, because that is a real error worth showing.
 */
export function hostEntryFromPairingUrl(
  input: string,
  options: { id: string; label?: string },
): HostEntry | null {
  const offer = parseConnectionOfferFromUrl(input);
  if (!offer) return null;

  return {
    id: options.id,
    type: "relay",
    label: options.label?.trim() || offer.serverId,
    // Stored verbatim. The TLS default belongs to the connection layer, not here.
    offer,
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx vitest run src/config/pairing.test.ts`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: build relay host entries from pairing URLs"
```

---

### Task 5: Connect to a host and keep the store current

**Files:**
- Create: `src/daemon/host-connection.ts`
- Test: `src/daemon/host-connection.test.ts`

**Interfaces:**
- Consumes: `HostEntry` (Task 3), `AgentStore` (Task 1).
- Produces: `createHostConnection(options: { entry: HostEntry; store: AgentStore }): HostConnection` where `HostConnection` is `{ close(): Promise<void> }`.

**Background the implementer needs:**

- The daemon requires a `fetch_agents_request` handshake after connect. Until it arrives, other requests hang silently. Seeding is therefore not optional — it is the handshake.
- `fetch_agents_response` entries are `{ agent, project }`; the snapshot is `entry.agent`.
- `DaemonClient` has no connection-state event. Status is derived by polling `getConnectionState()` and reacting to transitions. On a transition back to `connected`, re-seed.
- Pass `appVersion` — the daemon gates provider visibility on it. `"0.4.0"` is correct here.

- [ ] **Step 1: Write the failing integration test**

`src/daemon/host-connection.test.ts`:

```ts
import { afterEach, describe, expect, it } from "vitest";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import pino from "pino";
import { createPaseoDaemon } from "@getpaseo/server";
import { AgentStore } from "./agent-store.js";
import { createHostConnection } from "./host-connection.js";

interface Harness {
  port: number;
  stop: () => Promise<void>;
}

async function startDaemon(): Promise<Harness> {
  const root = await mkdtemp(path.join(os.tmpdir(), "paseo-icon-daemon-"));
  const paseoHome = path.join(root, ".paseo");
  await mkdir(paseoHome, { recursive: true });
  const staticDir = await mkdtemp(path.join(os.tmpdir(), "paseo-icon-static-"));

  const daemon = await createPaseoDaemon(
    {
      listen: "127.0.0.1:0",
      paseoHome,
      corsAllowedOrigins: [],
      hostnames: true,
      mcpEnabled: false,
      staticDir,
      mcpDebug: false,
      agentClients: {},
      agentStoragePath: path.join(paseoHome, "agents"),
      relayEnabled: false,
      relayEndpoint: "relay.paseo.sh:443",
      appBaseUrl: "https://app.paseo.sh",
    },
    pino({ level: "warn" }),
  );

  await daemon.start();
  const target = daemon.getListenTarget();
  if (!target || target.type !== "tcp") throw new Error("expected a TCP listener");

  return {
    port: target.port,
    stop: async () => {
      await daemon.stop().catch(() => undefined);
      await rm(root, { recursive: true, force: true });
      await rm(staticDir, { recursive: true, force: true });
    },
  };
}

async function waitFor(predicate: () => boolean, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("timed out waiting for condition");
}

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

describe("createHostConnection", () => {
  it("connects, seeds, and records the daemon's serverId", async () => {
    const harness = await startDaemon();
    cleanups.push(harness.stop);

    const store = new AgentStore();
    const connection = createHostConnection({
      entry: {
        id: "h1",
        label: "local",
        type: "directTcp",
        endpoint: `127.0.0.1:${harness.port}`,
        useTls: false,
      },
      store,
    });
    cleanups.push(() => connection.close());

    await waitFor(() => store.snapshot()[0]?.status === "connected");

    const host = store.snapshot()[0];
    expect(host?.agents).toEqual([]);
    expect(host?.serverId).toBeTruthy();
  });

  it("reports disconnected when the daemon goes away", async () => {
    const harness = await startDaemon();
    const store = new AgentStore();
    const connection = createHostConnection({
      entry: {
        id: "h1",
        label: "local",
        type: "directTcp",
        endpoint: `127.0.0.1:${harness.port}`,
        useTls: false,
      },
      store,
    });
    cleanups.push(() => connection.close());

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    await harness.stop();

    await waitFor(() => store.snapshot()[0]?.status === "disconnected");
  });
});
```

Note on scope: creating a real agent needs a provider binary that CI will not have, so these tests prove the connect, handshake, seed, serverId, and disconnect paths. Every state-derivation behavior is covered by the unit tests in Task 2 against synthetic snapshots.

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx vitest run src/daemon/host-connection.test.ts`
Expected: FAIL — cannot resolve `./host-connection.js`.

- [ ] **Step 3: Implement `src/daemon/host-connection.ts`**

```ts
import { DaemonClient } from "@getpaseo/client/internal/daemon-client";
import {
  buildRelayWebSocketUrl,
  shouldUseTlsForDefaultHostedRelay,
} from "@getpaseo/protocol/daemon-endpoints";
import type { HostEntry } from "../config/host-config.js";
import type { AgentStore } from "./agent-store.js";

const STATUS_POLL_MS = 1_000;
const AGENT_PAGE_LIMIT = 200;
const APP_VERSION = "0.4.0";

export interface HostConnection {
  close(): Promise<void>;
}

function isUnauthorized(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /\b401\b|unauthor|forbidden/i.test(message);
}

function buildClient(entry: HostEntry): DaemonClient {
  if (entry.type === "relay") {
    const { offer } = entry;
    return new DaemonClient({
      url: buildRelayWebSocketUrl({
        endpoint: offer.relay.endpoint,
        serverId: offer.serverId,
        role: "client",
        // Same default the CLI applies when an offer omits it.
        useTls: offer.relay.useTls ?? shouldUseTlsForDefaultHostedRelay(offer.relay.endpoint),
      }),
      clientType: "cli",
      appVersion: APP_VERSION,
      e2ee: { enabled: true, daemonPublicKeyB64: offer.daemonPublicKeyB64 },
      reconnect: { enabled: true },
    });
  }

  const scheme = entry.useTls ? "wss" : "ws";
  return new DaemonClient({
    url: `${scheme}://${entry.endpoint}/ws`,
    clientType: "cli",
    appVersion: APP_VERSION,
    ...(entry.password ? { password: entry.password } : {}),
    reconnect: { enabled: true },
  });
}

/**
 * Owns one host: connect, seed, subscribe, and keep the store's view of this
 * host's status honest.
 *
 * Seeding doubles as the daemon's required handshake — until a
 * `fetch_agents_request` arrives, other requests hang silently.
 */
export function createHostConnection(options: {
  entry: HostEntry;
  store: AgentStore;
}): HostConnection {
  const { entry, store } = options;
  store.setHost(entry.id, entry.label);

  const client = buildClient(entry);
  let closed = false;
  let lastStatus: string | null = null;

  const unsubscribe = client.on("agent_update", (message) => {
    const payload = message.payload;
    if (payload.kind === "upsert") {
      store.applyUpdate(entry.id, { kind: "upsert", agent: payload.agent });
    } else if (payload.kind === "remove") {
      store.applyUpdate(entry.id, { kind: "remove", agentId: payload.agentId });
    }
  });

  async function seed(): Promise<void> {
    const response = await client.fetchAgents({
      scope: "active",
      page: { limit: AGENT_PAGE_LIMIT },
      subscribe: {},
    });
    // Wholesale replacement: a subscription gap must not strand a dead agent.
    store.seed(
      entry.id,
      response.entries.map((item) => item.agent),
    );
    const serverId = client.getLastServerInfoMessage()?.serverId;
    if (serverId) store.setServerId(entry.id, serverId);
    store.setStatus(entry.id, "connected");
  }

  void (async () => {
    try {
      await client.connect();
      await seed();
    } catch (error) {
      if (closed) return;
      // A wrong password retried behind backoff forever is the failure mode
      // that wastes an afternoon, so stop and say so.
      store.setStatus(entry.id, isUnauthorized(error) ? "unauthorized" : "disconnected");
    }
  })();

  // DaemonClient exposes no connection-state event, so transitions are polled.
  const timer = setInterval(() => {
    if (closed) return;
    const status = client.getConnectionState().status;
    if (status === lastStatus) return;
    const previous = lastStatus;
    lastStatus = status;

    if (status === "connected" && previous !== null) {
      void seed().catch(() => store.setStatus(entry.id, "disconnected"));
      return;
    }
    if (status === "disconnected" || status === "disposed") {
      store.setStatus(entry.id, "disconnected");
    }
  }, STATUS_POLL_MS);

  return {
    async close() {
      closed = true;
      clearInterval(timer);
      unsubscribe();
      await client.close().catch(() => undefined);
      store.removeHost(entry.id);
    },
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx vitest run src/daemon/host-connection.test.ts`
Expected: PASS, 2 tests. First run is slow — the daemon boots for real.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: connect hosts and keep the agent store current"
```

---

### Task 6: Open an agent

**Files:**
- Create: `src/launch/open-agent.ts`
- Test: `src/launch/open-agent.test.ts`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `openAgent(target, deps)` where `target` is `{ serverId: string; agentId: string; webBaseUrl?: string }` and `deps` is `{ desktopAppInstalled: () => boolean; openExternal: (url: string) => void }`.

- [ ] **Step 1: Write the failing test**

`src/launch/open-agent.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import { defaultDesktopAppInstalled, openAgent } from "./open-agent.js";

describe("openAgent", () => {
  it("uses the paseo deep link when the desktop app is installed", () => {
    const openExternal = vi.fn();
    openAgent(
      { serverId: "srv-1", agentId: "a1" },
      { desktopAppInstalled: () => true, openExternal },
    );
    expect(openExternal).toHaveBeenCalledWith("paseo:/h/srv-1/agent/a1");
  });

  it("falls back to the daemon web UI when the desktop app is absent", () => {
    const openExternal = vi.fn();
    openAgent(
      { serverId: "srv-1", agentId: "a1", webBaseUrl: "http://127.0.0.1:6767" },
      { desktopAppInstalled: () => false, openExternal },
    );
    expect(openExternal).toHaveBeenCalledWith("http://127.0.0.1:6767/h/srv-1/agent/a1");
  });

  it("still tries the deep link when no web fallback is known", () => {
    const openExternal = vi.fn();
    openAgent(
      { serverId: "srv-1", agentId: "a1" },
      { desktopAppInstalled: () => false, openExternal },
    );
    expect(openExternal).toHaveBeenCalledWith("paseo:/h/srv-1/agent/a1");
  });

  it("percent-encodes ids so an odd serverId cannot break the route", () => {
    const openExternal = vi.fn();
    openAgent(
      { serverId: "srv 1", agentId: "a/1" },
      { desktopAppInstalled: () => true, openExternal },
    );
    expect(openExternal).toHaveBeenCalledWith("paseo:/h/srv%201/agent/a%2F1");
  });

  it("probes real filesystem paths without throwing", () => {
    expect(typeof defaultDesktopAppInstalled()).toBe("boolean");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx vitest run src/launch/open-agent.test.ts`
Expected: FAIL — cannot resolve `./open-agent.js`.

- [ ] **Step 3: Implement `src/launch/open-agent.ts`**

```ts
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import {
  buildAgentDeepLink,
  buildAgentDeepLinkRoute,
} from "@getpaseo/protocol/agent-deep-link";

export interface OpenAgentTarget {
  serverId: string;
  agentId: string;
  /** Daemon HTTP base URL, used only when the desktop app is not installed. */
  webBaseUrl?: string;
}

export interface OpenAgentDeps {
  desktopAppInstalled: () => boolean;
  openExternal: (url: string) => void;
}

/** Mirrors the install-path probe the Paseo CLI uses for `paseo open`. */
export function defaultDesktopAppInstalled(): boolean {
  const candidates: string[] =
    process.platform === "darwin"
      ? ["/Applications/Paseo.app", path.join(homedir(), "Applications", "Paseo.app")]
      : process.platform === "linux"
        ? ["/usr/bin/Paseo", "/opt/Paseo/Paseo", path.join(homedir(), "Applications", "Paseo.AppImage")]
        : process.env.LOCALAPPDATA
          ? [path.join(process.env.LOCALAPPDATA, "Programs", "Paseo", "Paseo.exe")]
          : [];

  return candidates.some((candidate) => existsSync(candidate));
}

export function openAgent(target: OpenAgentTarget, deps: OpenAgentDeps): void {
  const { serverId, agentId, webBaseUrl } = target;

  if (!deps.desktopAppInstalled() && webBaseUrl) {
    const route = buildAgentDeepLinkRoute({ serverId, agentId });
    deps.openExternal(`${webBaseUrl.replace(/\/+$/, "")}${route}`);
    return;
  }

  deps.openExternal(buildAgentDeepLink({ serverId, agentId }));
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx vitest run src/launch/open-agent.test.ts`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: open an agent via deep link with a web UI fallback"
```

---

### Task 7: Icons, tray presenter, and app wiring

**Files:**
- Create: `scripts/make-icons.mjs`
- Create: `src/tray/menu-template.ts`
- Create: `src/tray/tray-presenter.ts`
- Create: `src/main.ts`
- Test: `src/tray/menu-template.test.ts`

**Interfaces:**
- Consumes: `TrayViewModel` (Task 2), `AgentStore` (Task 1), `createHostConnection` (Task 5), `loadConfig`/`saveConfig` (Task 3), `hostEntryFromPairingUrl` (Task 4), `openAgent` (Task 6).
- Produces: `buildMenuTemplate(model, handlers, { loginItemEnabled })` returning `Electron.MenuItemConstructorOptions[]`; `createTrayPresenter({ store, assetsDir, handlers, isLoginItemEnabled })` returning `{ dispose(): void }`. `MenuHandlers` is `{ onOpenAgent, onAddHostFromClipboard, onEditConfig, onToggleLoginItem, onQuit }`.

The menu template is pure and tested; the presenter is thin Electron glue and is verified by hand.

- [ ] **Step 1: Write `scripts/make-icons.mjs`**

Three 16pt template icons at 1x and 2x. Template images are black-and-alpha only; macOS recolors them.

```js
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

const OUT = path.join(process.cwd(), "assets", "generated");

const SHAPES = {
  // Hollow circle: nothing needs you.
  idle: '<circle cx="8" cy="8" r="5.5" fill="none" stroke="black" stroke-width="1.5"/>',
  // Half-filled circle: work in progress.
  working:
    '<circle cx="8" cy="8" r="5.5" fill="none" stroke="black" stroke-width="1.5"/>' +
    '<path d="M8 2.5 A5.5 5.5 0 0 1 8 13.5 Z" fill="black"/>',
  // Filled circle: something is waiting on you.
  attention: '<circle cx="8" cy="8" r="5.5" fill="black"/>',
};

await mkdir(OUT, { recursive: true });

for (const [name, shape] of Object.entries(SHAPES)) {
  for (const scale of [1, 2]) {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">${shape}</svg>`;
    const suffix = scale === 1 ? "" : `@${scale}x`;
    const file = path.join(OUT, `${name}Template${suffix}.png`);
    await sharp(Buffer.from(svg)).resize(16 * scale, 16 * scale).png().toBuffer().then((data) => writeFile(file, data));
    console.log(`wrote ${file}`);
  }
}
```

- [ ] **Step 2: Generate the icons and confirm the files exist**

```bash
npm run icons && ls assets/generated
```

Expected: `idleTemplate.png`, `idleTemplate@2x.png`, `workingTemplate.png`, `workingTemplate@2x.png`, `attentionTemplate.png`, `attentionTemplate@2x.png`.

- [ ] **Step 3: Write the failing menu-template test**

`src/tray/menu-template.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import type { TrayViewModel } from "./view-model.js";
import { buildMenuTemplate } from "./menu-template.js";

const handlers = {
  onOpenAgent: vi.fn(),
  onAddHostFromClipboard: vi.fn(),
  onEditConfig: vi.fn(),
  onToggleLoginItem: vi.fn(),
  onQuit: vi.fn(),
};

const empty: TrayViewModel = { icon: "idle", count: 0, sections: [], hostStatuses: [] };

describe("buildMenuTemplate", () => {
  it("shows an explicit empty state", () => {
    const labels = buildMenuTemplate(empty, handlers, { loginItemEnabled: false }).map((i) => i.label);
    expect(labels).toContain("No agents");
  });

  it("renders attention rows with their reason", () => {
    const model: TrayViewModel = {
      icon: "attention",
      count: 1,
      sections: [
        {
          kind: "attention",
          rows: [
            {
              hostId: "h1",
              serverId: "srv-1",
              agentId: "a1",
              label: "Fix login",
              detail: "permission",
              hostLabel: null,
            },
          ],
          overflow: 0,
        },
      ],
      hostStatuses: [{ hostId: "h1", label: "laptop", status: "connected" }],
    };
    const labels = buildMenuTemplate(model, handlers, { loginItemEnabled: false }).map((i) => i.label);
    expect(labels).toContain("Needs you");
    expect(labels.some((label) => label?.includes("Fix login") && label.includes("permission"))).toBe(true);
  });

  it("renders the overflow row rather than dropping rows silently", () => {
    const model: TrayViewModel = {
      ...empty,
      sections: [{ kind: "attention", rows: [], overflow: 3 }],
    };
    const labels = buildMenuTemplate(model, handlers, { loginItemEnabled: false }).map((i) => i.label);
    expect(labels).toContain("…and 3 more");
  });

  it("puts idle agents in a submenu labelled with their count", () => {
    const model: TrayViewModel = {
      ...empty,
      sections: [
        {
          kind: "idle",
          rows: [
            { hostId: "h1", serverId: "srv-1", agentId: "a1", label: "one", detail: null, hostLabel: null },
            { hostId: "h1", serverId: "srv-1", agentId: "a2", label: "two", detail: null, hostLabel: null },
          ],
          overflow: 0,
        },
      ],
    };
    const template = buildMenuTemplate(model, handlers, { loginItemEnabled: false });
    const idle = template.find((item) => item.label === "Idle (2)");
    expect(idle?.submenu).toHaveLength(2);
  });

  it("shows a host status line per host", () => {
    const model: TrayViewModel = {
      ...empty,
      hostStatuses: [
        { hostId: "h1", label: "laptop", status: "connected" },
        { hostId: "h2", label: "studio", status: "unauthorized" },
      ],
    };
    const labels = buildMenuTemplate(model, handlers, { loginItemEnabled: false }).map((i) => i.label);
    expect(labels).toContain("laptop · connected");
    expect(labels).toContain("studio · authentication failed");
  });

  it("always offers the footer actions, because AppIndicator swallows left-click", () => {
    const labels = buildMenuTemplate(empty, handlers, { loginItemEnabled: true }).map((i) => i.label);
    expect(labels).toEqual(
      expect.arrayContaining([
        "Add host from clipboard…",
        "Edit configuration…",
        "Start at login",
        "Quit",
      ]),
    );
  });
});
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `npx vitest run src/tray/menu-template.test.ts`
Expected: FAIL — cannot resolve `./menu-template.js`.

- [ ] **Step 5: Implement `src/tray/menu-template.ts`**

```ts
import type { MenuItemConstructorOptions } from "electron";
import type { HostStatus } from "../daemon/agent-store.js";
import type { TrayAgentRow, TrayMenuSection, TrayViewModel } from "./view-model.js";

export interface MenuHandlers {
  onOpenAgent: (row: TrayAgentRow) => void;
  onAddHostFromClipboard: () => void;
  onEditConfig: () => void;
  onToggleLoginItem: (enabled: boolean) => void;
  onQuit: () => void;
}

const SECTION_TITLES = { attention: "Needs you", working: "Working", idle: "Idle" } as const;

const STATUS_TEXT: Record<HostStatus, string> = {
  connecting: "connecting",
  connected: "connected",
  disconnected: "disconnected",
  unauthorized: "authentication failed",
};

const REASON_TEXT: Record<string, string> = {
  finished: "done",
  permission: "permission",
  error: "error",
};

function rowLabel(row: TrayAgentRow): string {
  const parts = [row.label];
  if (row.detail) parts.push(REASON_TEXT[row.detail] ?? row.detail);
  if (row.hostLabel) parts.push(row.hostLabel);
  return parts.join("  ·  ");
}

function rowItem(row: TrayAgentRow, handlers: MenuHandlers): MenuItemConstructorOptions {
  return { label: rowLabel(row), click: () => handlers.onOpenAgent(row) };
}

function sectionItems(
  section: TrayMenuSection,
  handlers: MenuHandlers,
): MenuItemConstructorOptions[] {
  if (section.kind === "idle") {
    return [
      {
        label: `${SECTION_TITLES.idle} (${section.rows.length})`,
        submenu: section.rows.map((row) => rowItem(row, handlers)),
      },
    ];
  }

  const items: MenuItemConstructorOptions[] = [
    { label: SECTION_TITLES[section.kind], enabled: false },
    ...section.rows.map((row) => rowItem(row, handlers)),
  ];
  if (section.overflow > 0) {
    items.push({ label: `…and ${section.overflow} more`, enabled: false });
  }
  return items;
}

export function buildMenuTemplate(
  model: TrayViewModel,
  handlers: MenuHandlers,
  options: { loginItemEnabled: boolean },
): MenuItemConstructorOptions[] {
  const items: MenuItemConstructorOptions[] = [];

  if (model.sections.length === 0) {
    items.push({ label: "No agents", enabled: false });
  } else {
    for (const section of model.sections) items.push(...sectionItems(section, handlers));
  }

  if (model.hostStatuses.length > 0) {
    items.push({ type: "separator" });
    for (const host of model.hostStatuses) {
      items.push({ label: `${host.label} · ${STATUS_TEXT[host.status]}`, enabled: false });
    }
  }

  // Every action lives in the menu. AppIndicator desktops swallow left-click,
  // so nothing may be click-only.
  items.push(
    { type: "separator" },
    { label: "Add host from clipboard…", click: () => handlers.onAddHostFromClipboard() },
    { label: "Edit configuration…", click: () => handlers.onEditConfig() },
    {
      label: "Start at login",
      type: "checkbox",
      checked: options.loginItemEnabled,
      click: () => handlers.onToggleLoginItem(!options.loginItemEnabled),
    },
    { type: "separator" },
    { label: "Quit", click: () => handlers.onQuit() },
  );

  return items;
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `npx vitest run src/tray/menu-template.test.ts`
Expected: PASS, 6 tests.

- [ ] **Step 7: Implement `src/tray/tray-presenter.ts`**

```ts
import { Menu, Tray, nativeImage } from "electron";
import path from "node:path";
import type { AgentStore } from "../daemon/agent-store.js";
import { buildMenuTemplate, type MenuHandlers } from "./menu-template.js";
import { deriveTrayViewModel, type TrayIconState } from "./view-model.js";

const REBUILD_DEBOUNCE_MS = 120;

export interface TrayPresenter {
  dispose(): void;
}

export function createTrayPresenter(options: {
  store: AgentStore;
  assetsDir: string;
  handlers: MenuHandlers;
  isLoginItemEnabled: () => boolean;
}): TrayPresenter {
  const { store, assetsDir, handlers, isLoginItemEnabled } = options;

  const icons: Record<TrayIconState, Electron.NativeImage> = {
    idle: nativeImage.createFromPath(path.join(assetsDir, "idleTemplate.png")),
    working: nativeImage.createFromPath(path.join(assetsDir, "workingTemplate.png")),
    attention: nativeImage.createFromPath(path.join(assetsDir, "attentionTemplate.png")),
  };
  for (const image of Object.values(icons)) image.setTemplateImage(true);

  const tray = new Tray(icons.idle);
  let timer: NodeJS.Timeout | null = null;

  function render(): void {
    const model = deriveTrayViewModel(store.snapshot());
    tray.setImage(icons[model.icon]);
    // No platform supports a numeric badge on a tray icon. macOS gets the count
    // as adjacent text; elsewhere it rides the tooltip.
    if (process.platform === "darwin") {
      tray.setTitle(model.count > 0 ? String(model.count) : "");
    }
    tray.setToolTip(model.count > 0 ? `Paseo — ${model.count} need you` : "Paseo");
    tray.setContextMenu(
      Menu.buildFromTemplate(
        buildMenuTemplate(model, handlers, { loginItemEnabled: isLoginItemEnabled() }),
      ),
    );
  }

  const unsubscribe = store.subscribe(() => {
    if (timer) return;
    timer = setTimeout(() => {
      timer = null;
      render();
    }, REBUILD_DEBOUNCE_MS);
  });

  render();

  return {
    dispose() {
      if (timer) clearTimeout(timer);
      unsubscribe();
      tray.destroy();
    },
  };
}
```

- [ ] **Step 8: Implement `src/main.ts`**

```ts
import { app, clipboard, dialog, shell } from "electron";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { AgentStore } from "./daemon/agent-store.js";
import { createHostConnection, type HostConnection } from "./daemon/host-connection.js";
import {
  loadConfig,
  saveConfig,
  configPath,
  watchConfig,
  type AppConfig,
} from "./config/host-config.js";
import { hostEntryFromPairingUrl } from "./config/pairing.js";
import { defaultDesktopAppInstalled, openAgent } from "./launch/open-agent.js";
import { createTrayPresenter } from "./tray/tray-presenter.js";
import type { TrayAgentRow } from "./tray/view-model.js";

const DEFAULT_LOCAL_ENDPOINT = "127.0.0.1:6767";

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  const store = new AgentStore();
  const connections = new Map<string, HostConnection>();
  let configDir = "";

  async function ensureConfig(): Promise<AppConfig> {
    try {
      const config = await loadConfig(configDir);
      if (config.hosts.length > 0) return config;
      // First run: adopt the local daemon so there is nothing to configure.
      const seeded: AppConfig = {
        version: 1,
        hosts: [
          {
            id: randomUUID(),
            label: "This machine",
            type: "directTcp",
            endpoint: DEFAULT_LOCAL_ENDPOINT,
            useTls: false,
          },
        ],
      };
      await saveConfig(configDir, seeded);
      return seeded;
    } catch (error) {
      dialog.showErrorBox(
        "Paseo Icon — configuration error",
        `${configPath(configDir)}\n\n${error instanceof Error ? error.message : String(error)}`,
      );
      // Keep running with no hosts rather than dying; the menu offers a way out.
      return { version: 1, hosts: [] };
    }
  }

  let appliedHostsJson = "";

  /**
   * Rebuilds the connection fleet. Our own writes trip the config watcher, so
   * this no-ops when the host list is unchanged rather than churning sockets.
   */
  async function reconnectAll(config: AppConfig): Promise<void> {
    const hostsJson = JSON.stringify(config.hosts);
    if (hostsJson === appliedHostsJson) return;
    appliedHostsJson = hostsJson;

    for (const connection of connections.values()) await connection.close();
    connections.clear();
    for (const entry of config.hosts) {
      connections.set(entry.id, createHostConnection({ entry, store }));
    }
  }

  async function reloadFromDisk(): Promise<void> {
    try {
      await reconnectAll(await loadConfig(configDir));
    } catch (error) {
      dialog.showErrorBox(
        "Paseo Icon — configuration error",
        error instanceof Error ? error.message : String(error),
      );
    }
  }

  async function addHostFromClipboard(): Promise<void> {
    const text = clipboard.readText();
    let entry;
    try {
      entry = hostEntryFromPairingUrl(text, { id: randomUUID() });
    } catch (error) {
      dialog.showErrorBox(
        "Paseo Icon",
        `That pairing link is malformed.\n\n${error instanceof Error ? error.message : String(error)}`,
      );
      return;
    }
    if (!entry) {
      dialog.showErrorBox(
        "Paseo Icon",
        "No pairing link on the clipboard.\n\nRun `paseo daemon pair` and copy the link it prints.",
      );
      return;
    }

    const config = await loadConfig(configDir);
    config.hosts.push(entry);
    // The config watcher is the single reload path; writing is enough.
    await saveConfig(configDir, config);
    dialog.showMessageBox({ message: `Added host “${entry.label}”.` });
  }

  function handleOpenAgent(row: TrayAgentRow): void {
    if (!row.serverId) return;
    openAgent(
      { serverId: row.serverId, agentId: row.agentId },
      { desktopAppInstalled: defaultDesktopAppInstalled, openExternal: (url) => void shell.openExternal(url) },
    );
  }

  app.whenReady().then(async () => {
    app.dock?.hide();
    configDir = app.getPath("userData");

    const presenter = createTrayPresenter({
      store,
      assetsDir: path.join(app.getAppPath(), "assets", "generated"),
      isLoginItemEnabled: () => app.getLoginItemSettings().openAtLogin,
      handlers: {
        onOpenAgent: handleOpenAgent,
        onAddHostFromClipboard: () => void addHostFromClipboard(),
        onEditConfig: () => void shell.openPath(configPath(configDir)),
        onToggleLoginItem: (enabled) => app.setLoginItemSettings({ openAtLogin: enabled }),
        onQuit: () => app.quit(),
      },
    });

    const stopWatching = watchConfig(configDir, () => void reloadFromDisk());

    app.on("before-quit", () => {
      stopWatching();
      presenter.dispose();
      for (const connection of connections.values()) void connection.close();
    });

    await reconnectAll(await ensureConfig());
  });

  // No windows exist, so the default quit-on-all-closed behaviour must not apply.
  app.on("window-all-closed", () => undefined);
}
```

- [ ] **Step 9: Typecheck, test, and run the app by hand**

```bash
npm run typecheck && npm test && npm start
```

Expected: an icon appears in the menu bar. With the Paseo daemon running on 6767, the menu lists your agents. Verify by hand, since no automated harness can see a tray:

1. All agents idle → hollow icon, no number.
2. Start an agent → half-filled icon, still no number.
3. Let an agent finish → filled icon with `1` beside it; the menu shows it under `Needs you` with `done`.
4. Click that row → the desktop app opens on that agent.
5. Stop the daemon → within a couple of seconds the host line reads `disconnected` and the count clears.
6. Restart the daemon → it reconnects and the agents come back.
7. `Edit configuration…`, change a host label, save → the menu picks it up within a second without a restart.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: render the tray and wire the app together"
```

---

### Task 8: Package and release

**Files:**
- Create: `electron-builder.yml`
- Create: `.github/workflows/release.yml`
- Create: `README.md`

**Interfaces:**
- Consumes: the built `dist/` and `assets/generated/`.
- Produces: signed dmg and zip artifacts published to GitHub releases.

- [ ] **Step 1: Write `electron-builder.yml`**

`appId` must use a domain you control — `sh.paseo.*` is not yours. Substitute your own before the first build.

```yaml
appId: br.eng.gustavo.paseo-icon
productName: Paseo Icon
executableName: PaseoIcon
directories:
  output: release
files:
  - dist/**/*
  - assets/generated/**/*
  - "!**/*.map"
publish:
  provider: github
  owner: gustavoambrozio
  repo: paseo-icon
mac:
  category: public.app-category.developer-tools
  target:
    - dmg
    - zip
  hardenedRuntime: true
  notarize: true
  extendInfo:
    # No dock icon; this app is the menu bar item.
    LSUIElement: 1
```

- [ ] **Step 2: Write `README.md`**

It must state: what the app does, that it is AGPL-3.0-or-later, that it needs a running Paseo daemon, how first run adopts `127.0.0.1:6767` automatically, and how to add a remote host (`paseo daemon pair`, copy the link, then `Add host from clipboard…`). Include the `SHARP_IGNORE_GLOBAL_LIBVIPS=1` note for contributors on macOS with Homebrew libvips.

- [ ] **Step 3: Write `.github/workflows/release.yml`**

```yaml
name: release
on:
  push:
    tags: ["v*"]
  workflow_dispatch:

jobs:
  macos:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - run: npm ci
        env:
          SHARP_IGNORE_GLOBAL_LIBVIPS: "1"
      - run: npm run typecheck && npm test
      - run: npm run dist -- --publish always
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          CSC_LINK: ${{ secrets.CSC_LINK }}
          CSC_KEY_PASSWORD: ${{ secrets.CSC_KEY_PASSWORD }}
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_APP_SPECIFIC_PASSWORD: ${{ secrets.APPLE_APP_SPECIFIC_PASSWORD }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
```

Without the Apple secrets the build still runs but produces an unsigned app that triggers Gatekeeper. Set `notarize: false` and drop the Apple env vars if you are shipping only to yourself.

- [ ] **Step 4: Build locally and verify the app bundle**

```bash
npm run dist -- --publish never && open release/
```

Expected: a dmg in `release/`. Install it, launch it, confirm the icon appears with no dock icon and no window.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: package and release the app"
```

---

## Deferred (do not build)

From the spec, named so they stay choices rather than omissions: notifications, a preferences window, agent actions such as approving a permission, and a host registry shared with the Paseo desktop app. Windows and Linux builds are out until someone asks — Linux especially, because GNOME users must install a shell extension before a tray icon appears at all.
