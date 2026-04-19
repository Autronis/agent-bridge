# Bridge v2 — Plan 1: Eigenaar kolom + Agenda Swim Lanes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Foundation van bridge v2 — `eigenaar` en `gemaaktDoor` kolommen op agenda-items, POST /api/agenda accepteert ze, agenda dag-view rendert twee swim lanes (Sem/Syb) met clean blokken, team-blokken overspannen beide lanes, en de bridge `commit-planning.sh` stuurt de velden mee.

**Architecture:** Drizzle migration voegt twee kolommen toe (idempotent via `IF NOT EXISTS`). POST /api/agenda route wordt uitgebreid met validatie. Dashboard `dag-view.tsx` krijgt een nieuwe `SwimLaneView` sub-component achter de feature flag `agenda_lanes_v2` (nieuwe `feature_flags` tabel). Feature flag default off in prod; gezet op `on` nadat migration + UI getest zijn. Bridge script past request body aan.

**Tech Stack:** Next.js 14 App Router, Drizzle ORM (SQLite/Turso), React, Tailwind, Vitest. Bash voor bridge-scripts. Bestaande `UitlegBlock` component hergebruikt.

---

## File Structure

**Dashboard repo (`~/Autronis/Projects/autronis-dashboard/`):**
- Create: `drizzle/0010_bridge_v2_agenda_eigenaar.sql` — migration adding 2 columns + feature_flags table
- Modify: `src/lib/db/schema.ts` — add columns to `agendaItems`, export new `featureFlags` table
- Modify: `src/app/api/agenda/route.ts` — accept `eigenaar` + `gemaaktDoor` in POST (+ GET returns them)
- Create: `src/lib/feature-flags.ts` — helper `isFeatureEnabled(flag, userId?)`
- Create: `src/app/api/feature-flags/route.ts` — GET public endpoint (returns enabled flags for current user)
- Create: `src/app/(dashboard)/agenda/swim-lane-view.tsx` — new view component rendering 2 lanes
- Create: `src/app/(dashboard)/agenda/agenda-blok.tsx` — reusable blok component (extracted from dag-view)
- Modify: `src/app/(dashboard)/agenda/dag-view.tsx` — wire feature flag: lanes or legacy
- Create: `src/app/(dashboard)/agenda/__tests__/swim-lane-view.test.tsx` — Vitest unit tests
- Create: `src/app/api/agenda/__tests__/post.test.ts` — Vitest unit tests for POST route

**Agent-bridge repo (`~/Autronis/Projects/agent-bridge/`):**
- Modify: `scripts/commit-planning.sh` — send `eigenaar` + `gemaaktDoor=bridge` in request body
- Modify: `prompts/plan-avond.md` — add `"eigenaar"` to blok-schema

## Glossary

- **Lane**: een vertikale kolom in de agenda per gebruiker (sem/syb/vrij) of team-overspannend.
- **Eigenaar**: `sem | syb | team | vrij` — bepaalt in welke lane het blok rendert. `team` spant beide user-lanes.
- **gemaaktDoor**: `user | bridge | fallback-haiku | ai-plan-button` — audit trail voor waar het blok vandaan komt.
- **Feature flag `agenda_lanes_v2`**: bool — wanneer `true` rendert dag-view de swim lanes, anders de legacy layout.
- **Legacy layout**: bestaande overlappende paarse/groene blokken die Sem verwart.

---

## Task 1: Drizzle Migration — Eigenaar + GemaaktDoor + Feature Flags

**Files:**
- Create: `drizzle/0010_bridge_v2_agenda_eigenaar.sql`

- [ ] **Step 1: Write migration SQL**

Create `drizzle/0010_bridge_v2_agenda_eigenaar.sql`:
```sql
-- Bridge v2: agenda-item lane + audit + feature flags

ALTER TABLE agenda_items ADD COLUMN eigenaar TEXT NOT NULL DEFAULT 'vrij';
ALTER TABLE agenda_items ADD COLUMN gemaakt_door TEXT NOT NULL DEFAULT 'user';

CREATE INDEX IF NOT EXISTS idx_agenda_eigenaar_datum
  ON agenda_items (eigenaar, start_datum);

CREATE TABLE IF NOT EXISTS feature_flags (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  naam TEXT NOT NULL UNIQUE,
  actief INTEGER NOT NULL DEFAULT 0,
  alleen_voor_gebruiker_id INTEGER REFERENCES gebruikers(id),
  beschrijving TEXT,
  aangemaakt_op TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT INTO feature_flags (naam, actief, beschrijving)
VALUES ('agenda_lanes_v2', 0, 'Rendert agenda als swim lanes (sem/syb/vrij) — bridge v2')
ON CONFLICT(naam) DO NOTHING;
```

> Note: SQLite ALTER TABLE heeft geen native `IF NOT EXISTS` voor `ADD COLUMN`. Auto-migrate script moet de migration wrappen. Zie Task 2 stap 3.

- [ ] **Step 2: Verify migration parses** 

Run: `cd ~/Autronis/Projects/autronis-dashboard && sqlite3 /tmp/test-migrate.db < drizzle/0010_bridge_v2_agenda_eigenaar.sql`
Expected: exit code 0, geen errors. Cleanup: `rm /tmp/test-migrate.db`

Dit test alleen de syntax — je hebt een lege DB; `ALTER TABLE agenda_items` zal falen omdat tabel niet bestaat. Dus:

```bash
cd ~/Autronis/Projects/autronis-dashboard
# Generate current schema in test DB first, then apply migration
rm -f /tmp/test-migrate.db
cat drizzle/0000_fine_ultimo.sql drizzle/0001_*.sql drizzle/0002_*.sql drizzle/0003_*.sql drizzle/0004_*.sql drizzle/0005_*.sql drizzle/0006_*.sql drizzle/0007_certain_tinkerer.sql drizzle/0007_maandrapport.sql drizzle/0008_api_services.sql drizzle/0009_avatar_url.sql drizzle/0010_bridge_v2_agenda_eigenaar.sql | sqlite3 /tmp/test-migrate.db
echo ".schema agenda_items" | sqlite3 /tmp/test-migrate.db
echo ".schema feature_flags" | sqlite3 /tmp/test-migrate.db
```

Expected output contains `eigenaar TEXT NOT NULL DEFAULT 'vrij'`, `gemaakt_door TEXT NOT NULL DEFAULT 'user'`, and the `feature_flags` table. Cleanup: `rm /tmp/test-migrate.db`.

- [ ] **Step 3: Commit**

```bash
cd ~/Autronis/Projects/autronis-dashboard
git add drizzle/0010_bridge_v2_agenda_eigenaar.sql
git commit -m "feat(db): add eigenaar + gemaakt_door to agenda_items + feature_flags tabel"
```

---

## Task 2: Update Drizzle Schema + Types

**Files:**
- Modify: `src/lib/db/schema.ts` (around line 328 for agendaItems; append feature_flags)

- [ ] **Step 1: Add columns to `agendaItems`**

Edit `src/lib/db/schema.ts` at the `agendaItems` definition (starts line 328). The new columns go after `googleEventId`, before `aangemaaktOp`:

```typescript
export const agendaItems = sqliteTable("agenda_items", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  gebruikerId: integer("gebruiker_id").references(() => gebruikers.id),
  titel: text("titel").notNull(),
  omschrijving: text("omschrijving"),
  type: text("type", { enum: ["afspraak", "deadline", "belasting", "herinnering"] }).default("afspraak"),
  startDatum: text("start_datum").notNull(),
  eindDatum: text("eind_datum"),
  heleDag: integer("hele_dag").default(0),
  herinneringMinuten: integer("herinnering_minuten"),
  herinneringVerstuurdOp: text("herinnering_verstuurd_op"),
  googleEventId: text("google_event_id"),
  eigenaar: text("eigenaar", { enum: ["sem", "syb", "team", "vrij"] }).notNull().default("vrij"),
  gemaaktDoor: text("gemaakt_door", { enum: ["user", "bridge", "fallback-haiku", "ai-plan-button"] }).notNull().default("user"),
  aangemaaktOp: text("aangemaakt_op").default(sql`(datetime('now'))`),
}, (table) => ({
  idxStartDatum: index("idx_agenda_start_datum").on(table.startDatum),
  idxGebruikerId: index("idx_agenda_gebruiker").on(table.gebruikerId),
  idxEigenaarDatum: index("idx_agenda_eigenaar_datum").on(table.eigenaar, table.startDatum),
}));
```

- [ ] **Step 2: Append `featureFlags` table**

Append at end of file (before the last line):

```typescript
// ============ FEATURE FLAGS ============
export const featureFlags = sqliteTable("feature_flags", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  naam: text("naam").notNull().unique(),
  actief: integer("actief").notNull().default(0),
  alleenVoorGebruikerId: integer("alleen_voor_gebruiker_id").references(() => gebruikers.id),
  beschrijving: text("beschrijving"),
  aangemaaktOp: text("aangemaakt_op").notNull().default(sql`(datetime('now'))`),
});
```

- [ ] **Step 3: Verify auto-migrate picks up new migration**

Check `src/lib/db/auto-migrate.ts` — it reads from `drizzle/` and applies in order. Migration 0010 should get picked up automatically on next server start. No code change needed IF auto-migrate already wraps `ALTER TABLE ADD COLUMN` in try/catch for idempotency. If not:

Run: `grep -n 'ALTER TABLE\|ADD COLUMN\|already exists' src/lib/db/auto-migrate.ts | head`

If you see it catches "duplicate column" errors → fine. If not, wrap each `ALTER TABLE` statement from 0010 in try/catch. Expected fix (if needed):

```typescript
// In auto-migrate.ts, inside the migration loop, wrap statement execution:
try {
  await db.run(sql.raw(statement));
} catch (err: any) {
  // SQLite: "duplicate column name" or "table feature_flags already exists" — idempotent, skip
  const msg = err?.message || '';
  if (!/duplicate column|already exists/i.test(msg)) throw err;
}
```

- [ ] **Step 4: TypeScript check**

Run: `cd ~/Autronis/Projects/autronis-dashboard && npx tsc --noEmit 2>&1 | head -30`
Expected: no errors about `agendaItems` or `featureFlags`. If there are errors in other files that reference `agendaItems.X`, add the missing field reads or note them for later tasks.

- [ ] **Step 5: Commit**

```bash
cd ~/Autronis/Projects/autronis-dashboard
git add src/lib/db/schema.ts src/lib/db/auto-migrate.ts
git commit -m "feat(db): schema types voor eigenaar/gemaaktDoor + featureFlags"
```

---

## Task 3: Feature Flag Helper

**Files:**
- Create: `src/lib/feature-flags.ts`
- Create: `src/app/api/feature-flags/route.ts`
- Test: `src/lib/__tests__/feature-flags.test.ts`

- [ ] **Step 1: Write failing unit test**

Create `src/lib/__tests__/feature-flags.test.ts`:
```typescript
import { describe, it, expect, beforeAll, afterEach } from "vitest";
import { isFeatureEnabled, clearFeatureFlagCache } from "../feature-flags";
import { db } from "../db";
import { featureFlags } from "../db/schema";
import { eq } from "drizzle-orm";

describe("feature-flags", () => {
  afterEach(async () => {
    clearFeatureFlagCache();
    await db.delete(featureFlags).where(eq(featureFlags.naam, "test_flag"));
  });

  it("returns false when flag does not exist", async () => {
    expect(await isFeatureEnabled("nonexistent_flag")).toBe(false);
  });

  it("returns true when flag is actief=1 for everyone", async () => {
    await db.insert(featureFlags).values({ naam: "test_flag", actief: 1 });
    expect(await isFeatureEnabled("test_flag")).toBe(true);
  });

  it("returns true only for matching user when alleenVoorGebruikerId set", async () => {
    await db.insert(featureFlags).values({ naam: "test_flag", actief: 1, alleenVoorGebruikerId: 1 });
    expect(await isFeatureEnabled("test_flag", 1)).toBe(true);
    expect(await isFeatureEnabled("test_flag", 2)).toBe(false);
    expect(await isFeatureEnabled("test_flag")).toBe(false);
  });
});
```

- [ ] **Step 2: Run test — confirm it fails**

Run: `cd ~/Autronis/Projects/autronis-dashboard && npx vitest run src/lib/__tests__/feature-flags.test.ts`
Expected: FAIL — `isFeatureEnabled` and `clearFeatureFlagCache` don't exist yet.

- [ ] **Step 3: Implement `src/lib/feature-flags.ts`**

```typescript
import { db } from "./db";
import { featureFlags } from "./db/schema";
import { eq } from "drizzle-orm";

// Simple in-memory cache — flags rarely change, 60s TTL.
const cache = new Map<string, { at: number; value: boolean }>();
const TTL_MS = 60_000;

function key(naam: string, gebruikerId?: number) {
  return `${naam}:${gebruikerId ?? "all"}`;
}

export function clearFeatureFlagCache() {
  cache.clear();
}

export async function isFeatureEnabled(naam: string, gebruikerId?: number): Promise<boolean> {
  const k = key(naam, gebruikerId);
  const cached = cache.get(k);
  if (cached && Date.now() - cached.at < TTL_MS) return cached.value;

  const rows = await db.select().from(featureFlags).where(eq(featureFlags.naam, naam)).limit(1);
  const row = rows[0];
  let enabled = false;
  if (row && row.actief === 1) {
    if (row.alleenVoorGebruikerId == null) enabled = true;
    else enabled = row.alleenVoorGebruikerId === gebruikerId;
  }
  cache.set(k, { at: Date.now(), value: enabled });
  return enabled;
}
```

- [ ] **Step 4: Run tests — confirm pass**

Run: `cd ~/Autronis/Projects/autronis-dashboard && npx vitest run src/lib/__tests__/feature-flags.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Create public flag endpoint**

Create `src/app/api/feature-flags/route.ts`:
```typescript
import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { db } from "@/lib/db";
import { featureFlags } from "@/lib/db/schema";
import { and, eq, or, isNull } from "drizzle-orm";

// GET /api/feature-flags — returns { flags: { [naam]: boolean } } for current user
export async function GET() {
  try {
    const gebruiker = await requireAuth();
    const rows = await db
      .select()
      .from(featureFlags)
      .where(
        and(
          eq(featureFlags.actief, 1),
          or(
            isNull(featureFlags.alleenVoorGebruikerId),
            eq(featureFlags.alleenVoorGebruikerId, gebruiker.id)
          )
        )
      );
    const flags: Record<string, boolean> = {};
    for (const r of rows) flags[r.naam] = true;
    return NextResponse.json({ flags }, { headers: { "Cache-Control": "private, max-age=60" } });
  } catch (error) {
    return NextResponse.json(
      { fout: error instanceof Error ? error.message : "Onbekende fout" },
      { status: error instanceof Error && error.message === "Niet geauthenticeerd" ? 401 : 500 }
    );
  }
}
```

- [ ] **Step 6: Commit**

```bash
cd ~/Autronis/Projects/autronis-dashboard
git add src/lib/feature-flags.ts src/lib/__tests__/feature-flags.test.ts src/app/api/feature-flags/route.ts
git commit -m "feat(feature-flags): db-backed toggle met 60s cache + /api/feature-flags endpoint"
```

---

## Task 4: POST /api/agenda Accepts Eigenaar + GemaaktDoor

**Files:**
- Modify: `src/app/api/agenda/route.ts` (POST handler, currently line 53-103)
- Create: `src/app/api/agenda/__tests__/post.test.ts`

- [ ] **Step 1: Write failing unit test**

Create `src/app/api/agenda/__tests__/post.test.ts`:
```typescript
import { describe, it, expect, beforeAll, afterEach, vi } from "vitest";
import { POST } from "../route";
import { db } from "@/lib/db";
import { agendaItems } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

// Mock auth to simulate sem (id=1)
vi.mock("@/lib/auth", () => ({
  requireAuth: vi.fn(async () => ({ id: 1, naam: "sem", email: "sem@autronis.com" })),
  requireAuthOrApiKey: vi.fn(async () => ({ id: 1, naam: "sem" })),
}));

vi.mock("@/lib/google-calendar", () => ({
  pushEventToGoogle: vi.fn(async () => null),
}));

async function callPost(body: any) {
  const req = new Request("http://localhost/api/agenda", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return POST(req as any);
}

describe("POST /api/agenda", () => {
  afterEach(async () => {
    await db.delete(agendaItems).where(eq(agendaItems.titel, "TEST_POST_EIGENAAR"));
  });

  it("defaults eigenaar=vrij and gemaaktDoor=user when omitted", async () => {
    const res = await callPost({ titel: "TEST_POST_EIGENAAR", startDatum: "2026-05-01T09:00:00" });
    expect(res.status).toBe(201);
    const json: any = await res.json();
    expect(json.item.eigenaar).toBe("vrij");
    expect(json.item.gemaaktDoor).toBe("user");
  });

  it("accepts eigenaar=sem + gemaaktDoor=bridge", async () => {
    const res = await callPost({
      titel: "TEST_POST_EIGENAAR",
      startDatum: "2026-05-01T09:00:00",
      eigenaar: "sem",
      gemaaktDoor: "bridge",
    });
    expect(res.status).toBe(201);
    const json: any = await res.json();
    expect(json.item.eigenaar).toBe("sem");
    expect(json.item.gemaaktDoor).toBe("bridge");
  });

  it("rejects invalid eigenaar value with 400", async () => {
    const res = await callPost({
      titel: "TEST_POST_EIGENAAR",
      startDatum: "2026-05-01T09:00:00",
      eigenaar: "foo",
    });
    expect(res.status).toBe(400);
    const json: any = await res.json();
    expect(json.fout).toMatch(/eigenaar/i);
  });

  it("rejects invalid gemaaktDoor value with 400", async () => {
    const res = await callPost({
      titel: "TEST_POST_EIGENAAR",
      startDatum: "2026-05-01T09:00:00",
      gemaaktDoor: "random",
    });
    expect(res.status).toBe(400);
    const json: any = await res.json();
    expect(json.fout).toMatch(/gemaaktDoor/i);
  });
});
```

- [ ] **Step 2: Run test — confirm fail**

Run: `cd ~/Autronis/Projects/autronis-dashboard && npx vitest run src/app/api/agenda/__tests__/post.test.ts`
Expected: FAIL (4 tests — existing POST doesn't know about these fields).

- [ ] **Step 3: Update POST handler**

Edit `src/app/api/agenda/route.ts`. Replace the POST function body (current lines 53-103) with:

```typescript
const VALID_EIGENAAR = ["sem", "syb", "team", "vrij"] as const;
const VALID_GEMAAKT_DOOR = ["user", "bridge", "fallback-haiku", "ai-plan-button"] as const;

export async function POST(req: NextRequest) {
  try {
    const gebruiker = await requireAuth();
    const body = await req.json();

    if (!body.titel?.trim()) {
      return NextResponse.json({ fout: "Titel is verplicht." }, { status: 400 });
    }
    if (!body.startDatum) {
      return NextResponse.json({ fout: "Startdatum is verplicht." }, { status: 400 });
    }

    const eigenaar = body.eigenaar ?? "vrij";
    if (!VALID_EIGENAAR.includes(eigenaar)) {
      return NextResponse.json(
        { fout: `Ongeldige eigenaar '${eigenaar}'. Verwacht één van: ${VALID_EIGENAAR.join(", ")}.` },
        { status: 400 }
      );
    }

    const gemaaktDoor = body.gemaaktDoor ?? "user";
    if (!VALID_GEMAAKT_DOOR.includes(gemaaktDoor)) {
      return NextResponse.json(
        { fout: `Ongeldige gemaaktDoor '${gemaaktDoor}'. Verwacht één van: ${VALID_GEMAAKT_DOOR.join(", ")}.` },
        { status: 400 }
      );
    }

    const [nieuw] = await db
      .insert(agendaItems)
      .values({
        gebruikerId: gebruiker.id,
        titel: body.titel.trim(),
        omschrijving: body.omschrijving?.trim() || null,
        type: body.type || "afspraak",
        startDatum: body.startDatum,
        eindDatum: body.eindDatum || null,
        heleDag: body.heleDag ? 1 : 0,
        herinneringMinuten: body.herinneringMinuten ?? null,
        eigenaar,
        gemaaktDoor,
      })
      .returning();

    pushEventToGoogle(gebruiker.id, {
      summary: body.titel.trim(),
      description: body.omschrijving?.trim(),
      start: body.startDatum,
      end: body.eindDatum || undefined,
      allDay: !!body.heleDag,
    })
      .then(async (event) => {
        if (event?.id) {
          await db.update(agendaItems)
            .set({ googleEventId: event.id })
            .where(eq(agendaItems.id, nieuw.id))
            .execute();
        }
      })
      .catch(() => {});

    return NextResponse.json({ item: nieuw }, { status: 201 });
  } catch (error) {
    return NextResponse.json(
      { fout: error instanceof Error ? error.message : "Onbekende fout" },
      { status: error instanceof Error && error.message === "Niet geauthenticeerd" ? 401 : 500 }
    );
  }
}
```

Also update the GET handler `select({...})` block (around line 22) to include the new fields:

```typescript
    const items = await db
      .select({
        id: agendaItems.id,
        gebruikerId: agendaItems.gebruikerId,
        gebruikerNaam: gebruikers.naam,
        titel: agendaItems.titel,
        omschrijving: agendaItems.omschrijving,
        type: agendaItems.type,
        startDatum: agendaItems.startDatum,
        eindDatum: agendaItems.eindDatum,
        heleDag: agendaItems.heleDag,
        herinneringMinuten: agendaItems.herinneringMinuten,
        googleEventId: agendaItems.googleEventId,
        eigenaar: agendaItems.eigenaar,
        gemaaktDoor: agendaItems.gemaaktDoor,
      })
      .from(agendaItems)
      .leftJoin(gebruikers, eq(agendaItems.gebruikerId, gebruikers.id))
      .where(conditions.length > 0 ? and(...conditions) : undefined)
      .orderBy(agendaItems.startDatum);
```

- [ ] **Step 4: Run tests — confirm pass**

Run: `cd ~/Autronis/Projects/autronis-dashboard && npx vitest run src/app/api/agenda/__tests__/post.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/Autronis/Projects/autronis-dashboard
git add src/app/api/agenda/route.ts src/app/api/agenda/__tests__/post.test.ts
git commit -m "feat(agenda): POST/GET accept eigenaar + gemaaktDoor met validatie"
```

---

## Task 5: Extract AgendaBlok Component

**Files:**
- Create: `src/app/(dashboard)/agenda/agenda-blok.tsx`

The current `dag-view.tsx` (1577 regels) renders blocks inline. For swim lanes we need a reusable component. This task extracts the block-rendering into its own file with the v2 visual spec.

- [ ] **Step 1: Write component**

Create `src/app/(dashboard)/agenda/agenda-blok.tsx`:
```typescript
"use client";

import { cn } from "@/lib/utils";

export interface AgendaBlokProps {
  id: number;
  titel: string;
  omschrijving?: string | null;
  type: "afspraak" | "deadline" | "belasting" | "herinnering" | "taak" | "claude";
  startDatum: string;
  eindDatum?: string | null;
  eigenaar: "sem" | "syb" | "team" | "vrij";
  gemaaktDoor?: string;
  projectNaam?: string | null;
  projectKleur?: string | null;
  onClick?: () => void;
}

const TYPE_LABEL: Record<string, string> = {
  claude: "CLAUDE",
  taak: "TAAK",
  afspraak: "MEETING",
  deadline: "DEADLINE",
  belasting: "BELASTING",
  herinnering: "HERINNERING",
};

function formatTime(iso: string): string {
  const d = new Date(iso);
  const h = String(d.getHours()).padStart(2, "0");
  const m = String(d.getMinutes()).padStart(2, "0");
  return `${h}:${m}`;
}

function durationMinutes(start: string, end?: string | null): number {
  if (!end) return 30;
  const s = new Date(start).getTime();
  const e = new Date(end).getTime();
  return Math.max(15, Math.round((e - s) / 60000));
}

function durationLabel(mins: number): string {
  if (mins < 60) return `${mins}m`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return m === 0 ? `${h}u` : `${h}u${m}m`;
}

export function AgendaBlok({
  titel,
  omschrijving,
  type,
  startDatum,
  eindDatum,
  eigenaar,
  projectNaam,
  projectKleur,
  onClick,
}: AgendaBlokProps) {
  const mins = durationMinutes(startDatum, eindDatum);
  // 1 minute = 1.6px height baseline (30m → 48px)
  const heightPx = Math.max(32, Math.round(mins * 1.6));
  const accentColor = projectKleur || "#2A3538";

  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "group relative w-full text-left rounded-md border border-border bg-card/50 hover:bg-card/80 transition-colors",
        "pl-3 pr-2 py-1.5 overflow-hidden",
        eigenaar === "team" && "ring-1 ring-purple-500/40",
      )}
      style={{ height: `${heightPx}px`, borderLeft: `4px solid ${accentColor}` }}
      data-testid="agenda-blok"
      data-eigenaar={eigenaar}
      data-type={type}
    >
      {projectNaam && (
        <div
          className="text-[11px] uppercase tracking-wider font-semibold truncate"
          style={{ color: accentColor }}
        >
          {projectNaam}
        </div>
      )}
      <div className="flex items-start justify-between gap-2">
        <div className="text-sm font-medium text-foreground line-clamp-2 leading-snug flex-1">
          {titel}
        </div>
        <span className="text-[10px] tabular-nums text-muted-foreground shrink-0 mt-0.5">
          {durationLabel(mins)}
        </span>
      </div>
      {omschrijving && mins >= 60 && (
        <div className="text-[11px] text-muted-foreground line-clamp-2 mt-0.5">{omschrijving}</div>
      )}
      <span className="absolute bottom-1 right-1.5 text-[9px] font-semibold uppercase tracking-wider text-muted-foreground px-1.5 py-0.5 rounded bg-background/50">
        {TYPE_LABEL[type] || type}
      </span>
      <span className="absolute top-1 left-1.5 text-[10px] tabular-nums text-muted-foreground">
        {formatTime(startDatum)}
      </span>
    </button>
  );
}
```

- [ ] **Step 2: Verify it builds**

Run: `cd ~/Autronis/Projects/autronis-dashboard && npx tsc --noEmit src/app/\(dashboard\)/agenda/agenda-blok.tsx 2>&1 | head -10`
Expected: no TypeScript errors. If the shell eats the parens, use `"src/app/(dashboard)/agenda/agenda-blok.tsx"` quoted.

- [ ] **Step 3: Commit**

```bash
cd ~/Autronis/Projects/autronis-dashboard
git add "src/app/(dashboard)/agenda/agenda-blok.tsx"
git commit -m "feat(agenda): AgendaBlok component met accent-rand + type-badge + duur"
```

---

## Task 6: SwimLaneView Component

**Files:**
- Create: `src/app/(dashboard)/agenda/swim-lane-view.tsx`
- Test: `src/app/(dashboard)/agenda/__tests__/swim-lane-view.test.tsx`

- [ ] **Step 1: Write failing tests**

Create `src/app/(dashboard)/agenda/__tests__/swim-lane-view.test.tsx`:
```typescript
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { SwimLaneView } from "../swim-lane-view";

const datum = "2026-05-01";

describe("SwimLaneView", () => {
  const items = [
    { id: 1, titel: "Sem taak", startDatum: `${datum}T09:00:00`, eindDatum: `${datum}T10:00:00`, eigenaar: "sem", type: "taak" },
    { id: 2, titel: "Syb taak", startDatum: `${datum}T09:00:00`, eindDatum: `${datum}T10:30:00`, eigenaar: "syb", type: "taak" },
    { id: 3, titel: "Team meeting", startDatum: `${datum}T11:00:00`, eindDatum: `${datum}T12:00:00`, eigenaar: "team", type: "afspraak" },
    { id: 4, titel: "Fietsenzaak onboard", startDatum: `${datum}T14:00:00`, eindDatum: `${datum}T15:00:00`, eigenaar: "vrij", type: "taak" },
  ];

  it("renders 3 lane columns (sem, syb, vrij)", () => {
    render(<SwimLaneView datum={datum} items={items as any} />);
    expect(screen.getByTestId("lane-sem")).toBeDefined();
    expect(screen.getByTestId("lane-syb")).toBeDefined();
    expect(screen.getByTestId("lane-vrij")).toBeDefined();
  });

  it("places sem item in sem lane", () => {
    render(<SwimLaneView datum={datum} items={items as any} />);
    const lane = screen.getByTestId("lane-sem");
    expect(lane.textContent).toContain("Sem taak");
    expect(lane.textContent).not.toContain("Syb taak");
  });

  it("places team item in the team overlay (spans lanes)", () => {
    render(<SwimLaneView datum={datum} items={items as any} />);
    const overlay = screen.getByTestId("team-overlay");
    expect(overlay.textContent).toContain("Team meeting");
  });

  it("places vrij item in vrij lane", () => {
    render(<SwimLaneView datum={datum} items={items as any} />);
    const lane = screen.getByTestId("lane-vrij");
    expect(lane.textContent).toContain("Fietsenzaak onboard");
  });

  it("renders lunch overlay 12:30-13:30", () => {
    render(<SwimLaneView datum={datum} items={items as any} />);
    expect(screen.getByTestId("lunch-overlay")).toBeDefined();
  });
});
```

- [ ] **Step 2: Run tests — confirm fail**

Run: `cd ~/Autronis/Projects/autronis-dashboard && npx vitest run "src/app/(dashboard)/agenda/__tests__/swim-lane-view.test.tsx"`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement SwimLaneView**

Create `src/app/(dashboard)/agenda/swim-lane-view.tsx`:
```typescript
"use client";

import { AgendaBlok, AgendaBlokProps } from "./agenda-blok";

type Item = AgendaBlokProps & { gebruikerId?: number };

interface Props {
  datum: string; // "YYYY-MM-DD"
  items: Item[];
  dagStart?: number; // hour, default 8
  dagEind?: number;  // hour, default 19
  onItemClick?: (id: number) => void;
}

const HOUR_HEIGHT_PX = 96; // 1 hour = 96px (30m = 48px)

function hourOffset(iso: string, dagStart: number): number {
  const d = new Date(iso);
  const h = d.getHours() + d.getMinutes() / 60;
  return (h - dagStart) * HOUR_HEIGHT_PX;
}

export function SwimLaneView({ datum, items, dagStart = 8, dagEind = 19, onItemClick }: Props) {
  const totalHeight = (dagEind - dagStart) * HOUR_HEIGHT_PX;

  const semItems = items.filter((i) => i.eigenaar === "sem");
  const sybItems = items.filter((i) => i.eigenaar === "syb");
  const vrijItems = items.filter((i) => i.eigenaar === "vrij");
  const teamItems = items.filter((i) => i.eigenaar === "team");

  const hours: number[] = [];
  for (let h = dagStart; h <= dagEind; h++) hours.push(h);

  const renderLane = (laneItems: Item[], testId: string, label: string, widthClass: string) => (
    <div className={`relative border-r border-border ${widthClass}`} data-testid={testId}>
      <div className="sticky top-0 z-10 bg-background/80 backdrop-blur px-3 py-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground border-b border-border">
        {label}
      </div>
      <div className="relative" style={{ height: `${totalHeight}px` }}>
        {laneItems.map((it) => (
          <div
            key={it.id}
            className="absolute left-1 right-1"
            style={{ top: `${hourOffset(it.startDatum, dagStart)}px` }}
          >
            <AgendaBlok {...it} onClick={onItemClick ? () => onItemClick(it.id) : undefined} />
          </div>
        ))}
      </div>
    </div>
  );

  // Lunch overlay: 12:30 - 13:30
  const lunchTop = (12.5 - dagStart) * HOUR_HEIGHT_PX;
  const lunchHeight = HOUR_HEIGHT_PX; // 1 hour

  return (
    <div className="flex w-full border border-border rounded-lg overflow-hidden">
      {/* Time ruler */}
      <div className="w-14 shrink-0 border-r border-border bg-background/50">
        <div className="sticky top-0 z-10 h-9 border-b border-border" />
        <div className="relative" style={{ height: `${totalHeight}px` }}>
          {hours.map((h) => (
            <div
              key={h}
              className="absolute left-0 right-0 text-[11px] tabular-nums text-muted-foreground pr-1 text-right"
              style={{ top: `${(h - dagStart) * HOUR_HEIGHT_PX - 6}px` }}
            >
              {String(h).padStart(2, "0")}:00
            </div>
          ))}
        </div>
      </div>

      {/* Lanes container (for team-overlay + lunch positioning) */}
      <div className="flex flex-1 relative">
        {renderLane(semItems, "lane-sem", "Sem", "flex-1")}
        {renderLane(sybItems, "lane-syb", "Syb", "flex-1")}
        {renderLane(vrijItems, "lane-vrij", "Vrij", "w-32")}

        {/* Lunch overlay — spans all lanes */}
        <div
          className="absolute left-0 right-0 bg-muted/20 border-y border-border pointer-events-none flex items-center justify-center text-[11px] uppercase tracking-widest text-muted-foreground"
          style={{ top: `${36 + lunchTop}px`, height: `${lunchHeight}px` }}
          data-testid="lunch-overlay"
        >
          lunch
        </div>

        {/* Team overlay — items positioned on top of both sem+syb lanes */}
        <div
          className="absolute pointer-events-none"
          style={{ top: "36px", left: 0, right: 0, height: `${totalHeight}px` }}
          data-testid="team-overlay"
        >
          {teamItems.map((it) => (
            <div
              key={it.id}
              className="absolute pointer-events-auto"
              style={{
                top: `${hourOffset(it.startDatum, dagStart)}px`,
                // span sem + syb lanes (excluding vrij)
                left: "0.25rem",
                right: `calc(8rem + 0.25rem)`,
              }}
            >
              <AgendaBlok {...it} onClick={onItemClick ? () => onItemClick(it.id) : undefined} />
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Run tests — confirm pass**

Run: `cd ~/Autronis/Projects/autronis-dashboard && npx vitest run "src/app/(dashboard)/agenda/__tests__/swim-lane-view.test.tsx"`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/Autronis/Projects/autronis-dashboard
git add "src/app/(dashboard)/agenda/swim-lane-view.tsx" "src/app/(dashboard)/agenda/__tests__/swim-lane-view.test.tsx"
git commit -m "feat(agenda): SwimLaneView component met sem/syb/vrij lanes + team overlay + lunch"
```

---

## Task 7: Wire Feature Flag in DagView

**Files:**
- Modify: `src/app/(dashboard)/agenda/dag-view.tsx`

- [ ] **Step 1: Add flag fetch at top of component**

Open `src/app/(dashboard)/agenda/dag-view.tsx`. At the top of the main DagView component (find the `export function` or `export default function` declaration; it's inside a large file — use grep to locate):

```bash
grep -n "export function DagView\|export default function" "src/app/(dashboard)/agenda/dag-view.tsx" | head
```

- [ ] **Step 2: Add feature flag state**

Near the top of the DagView component body, before other `useState` hooks, add:

```typescript
const [lanesV2, setLanesV2] = useState(false);

useEffect(() => {
  fetch("/api/feature-flags", { cache: "no-store" })
    .then((r) => r.json())
    .then((j) => setLanesV2(!!j.flags?.agenda_lanes_v2))
    .catch(() => {});
}, []);
```

Make sure `useState`, `useEffect` are imported from React.

- [ ] **Step 3: Conditionally render SwimLaneView**

Find the JSX return block in `DagView`. Wrap the existing render with:

```typescript
import { SwimLaneView } from "./swim-lane-view";
import { UitlegBlock } from "@/components/ui/uitleg-block";

// ...inside the return, above the existing layout:

if (lanesV2) {
  return (
    <div className="space-y-4">
      <UitlegBlock id="agenda-lanes-v2-uitleg" titel="Agenda in swim lanes">
        <p>
          Links de Sem-lane, rechts Syb. Team-afspraken (zoals klant-meetings) spannen beide lanes.
          De smalle Vrij-lane rechts toont werk dat nog niet is opgepakt — sleep het naar je eigen
          lane om 't zelf te pakken.
        </p>
        <p>
          Het gekleurde randje links van elk blok laat je in één oogopslag zien aan welke klant
          je werkt. Lunch (12:30–13:30) is grijs; loopt door alle lanes.
        </p>
      </UitlegBlock>

      <SwimLaneView
        datum={huidigeDatum}
        items={itemsVoorDagMetEigenaar}
        onItemClick={(id) => openItemModal(id)}
      />
    </div>
  );
}

// ...fallback to existing legacy render below
```

**Adapt to actual variable names:** the above uses `huidigeDatum`, `itemsVoorDagMetEigenaar`, `openItemModal` as placeholders. Locate the real variable names in `dag-view.tsx` — likely `datum`, `items`, and an existing onClick handler. `itemsVoorDagMetEigenaar` needs to be a mapped version of the fetched agenda items that includes the `eigenaar` field (the API already returns it after Task 4, so just pass the items through).

- [ ] **Step 4: Sanity check — type compile**

Run: `cd ~/Autronis/Projects/autronis-dashboard && npx tsc --noEmit 2>&1 | grep -E "dag-view|swim-lane" | head -20`
Expected: no errors. If there are, fix the variable names based on the actual dag-view.tsx code.

- [ ] **Step 5: Manual smoke test**

Run: `cd ~/Autronis/Projects/autronis-dashboard && npm run dev`. Open `http://localhost:3000/agenda` in browser.

Enable the flag manually:
```bash
sqlite3 data/autronis.db "UPDATE feature_flags SET actief=1 WHERE naam='agenda_lanes_v2';"
```

Hard-reload browser. Expected: agenda renders with two main lanes + a smaller vrij lane + lunch grey stripe. If items don't appear, check their `eigenaar` field — existing rows default to `vrij`, so they'll all land in the vrij lane until bridge writes new ones or you update manually.

Disable again (for now):
```bash
sqlite3 data/autronis.db "UPDATE feature_flags SET actief=0 WHERE naam='agenda_lanes_v2';"
```

- [ ] **Step 6: Commit**

```bash
cd ~/Autronis/Projects/autronis-dashboard
git add "src/app/(dashboard)/agenda/dag-view.tsx"
git commit -m "feat(agenda): wire agenda_lanes_v2 feature flag in DagView met UitlegBlock"
```

---

## Task 8: Update Bridge commit-planning.sh

**Files:**
- Modify: `~/Autronis/Projects/agent-bridge/scripts/commit-planning.sh`
- Modify: `~/Autronis/Projects/agent-bridge/prompts/plan-avond.md`

- [ ] **Step 1: Update prompt to include eigenaar in output JSON**

Open `~/Autronis/Projects/agent-bridge/prompts/plan-avond.md`. In the "Output format" section, update the blok schema inside `blokken[]` to:

```json
{
  "start": "09:00",
  "eind": "10:30",
  "titel": "Korte titel",
  "taakId": 123,
  "type": "taak|cluster|meeting|buffer",
  "eigenaar": "sem|syb|team|vrij",
  "toelichting": "1 zin waarom"
}
```

Add a rule under "Regels":
```
9. **Eigenaar altijd expliciet**: gebruik `{{USER_NAME}}` voor je eigen blokken, `team` als het een klant-meeting / intake met beiden is, `vrij` alleen voor werk dat nog gepakt moet worden.
```

- [ ] **Step 2: Update commit-planning.sh to send eigenaar + gemaaktDoor**

Open `~/Autronis/Projects/agent-bridge/scripts/commit-planning.sh`. In the Python heredoc where `body = { ... }` is built, change to:

```python
    body = {
        "titel": b["titel"],
        "omschrijving": b.get("toelichting", ""),
        "startDatum": start_iso,
        "eindDatum": eind_iso,
        "type": "afspraak" if b.get("type") == "meeting" else "afspraak",
        "eigenaar": b.get("eigenaar", os.environ.get("BRIDGE_USER", "vrij")),
        "gemaaktDoor": "bridge",
    }
```

(Note: the existing `type: "taak" if ... else "blok"` was wrong — agenda only knows afspraak/deadline/belasting/herinnering. Use `afspraak` for both cases. If you need to distinguish claude vs user in the UI, use gemaaktDoor.)

And at the top of the heredoc, add after the existing imports (the `python3 <<PY` body):
```python
import os
```

- [ ] **Step 3: Delete-before-write for re-run semantics**

Before the for-loop over blokken, add:
```python
# Re-run semantics: delete existing bridge-generated rows for this date+eigenaar
# so we don't double-post.
eigenaar_user = os.environ.get("BRIDGE_USER", "vrij")
delete_url = f"{url}/api/agenda/bridge-reset"
r = subprocess.run(
    ["curl", "-s", "-X", "POST", delete_url,
     "-H", f"Authorization: Bearer {key}",
     "-H", "Content-Type: application/json",
     "-d", json.dumps({"datum": datum, "eigenaar": eigenaar_user})],
    capture_output=True, text=True
)
# Silent on fail — endpoint may not exist yet; commit continues
```

- [ ] **Step 4: Set BRIDGE_USER in plan-avond.sh**

Open `~/Autronis/Projects/agent-bridge/scripts/plan-avond.sh`. Before the `bash "$PROJECT_DIR/scripts/commit-planning.sh"` call, add:

```bash
export BRIDGE_USER="$USER_NAME"
```

- [ ] **Step 5: Create /api/agenda/bridge-reset endpoint**

Create `~/Autronis/Projects/autronis-dashboard/src/app/api/agenda/bridge-reset/route.ts`:
```typescript
import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db";
import { agendaItems } from "@/lib/db/schema";
import { requireAuthOrApiKey } from "@/lib/auth";
import { and, eq, gte, lt } from "drizzle-orm";

// POST /api/agenda/bridge-reset — delete bridge-generated rows for a (datum, eigenaar)
export async function POST(req: NextRequest) {
  try {
    await requireAuthOrApiKey(req);
    const body = await req.json();
    const datum = body.datum; // "YYYY-MM-DD"
    const eigenaar = body.eigenaar;
    if (!datum || !eigenaar) {
      return NextResponse.json({ fout: "datum en eigenaar zijn verplicht." }, { status: 400 });
    }
    const dagStart = `${datum}T00:00:00`;
    const dagEind = `${datum}T23:59:59`;
    const result = await db
      .delete(agendaItems)
      .where(
        and(
          eq(agendaItems.gemaaktDoor, "bridge"),
          eq(agendaItems.eigenaar, eigenaar),
          gte(agendaItems.startDatum, dagStart),
          lt(agendaItems.startDatum, dagEind),
        )
      )
      .returning({ id: agendaItems.id });
    return NextResponse.json({ verwijderd: result.length });
  } catch (error) {
    return NextResponse.json(
      { fout: error instanceof Error ? error.message : "Onbekende fout" },
      { status: 500 }
    );
  }
}
```

- [ ] **Step 6: Commit in dashboard repo**

```bash
cd ~/Autronis/Projects/autronis-dashboard
git add src/app/api/agenda/bridge-reset/route.ts
git commit -m "feat(agenda): POST /api/agenda/bridge-reset voor bridge re-run dedup"
```

- [ ] **Step 7: Commit in agent-bridge repo**

```bash
cd ~/Autronis/Projects/agent-bridge
git add scripts/commit-planning.sh scripts/plan-avond.sh prompts/plan-avond.md
git commit -m "feat(bridge): stuur eigenaar + gemaaktDoor naar /api/agenda, reset bridge rows"
```

---

## Task 9: E2E Dry-Run Validation

**Files:**
- Modify: `~/Autronis/Projects/agent-bridge/tests/test-dry-run.sh` (optional extension)

- [ ] **Step 1: Enable flag in dev DB**

```bash
cd ~/Autronis/Projects/autronis-dashboard
sqlite3 data/autronis.db "UPDATE feature_flags SET actief=1 WHERE naam='agenda_lanes_v2';"
```

- [ ] **Step 2: Run bridge dry-run**

```bash
cd ~/Autronis/Projects/agent-bridge
bash tests/test-dry-run.sh
```

Expected: Discord post verschijnt; NO dashboard writes (dry_run=true).

- [ ] **Step 3: Run a real single run (not dry)**

Temporarily set `dry_run: false` in `~/.config/autronis/agent-bridge.json`, then:
```bash
cd ~/Autronis/Projects/agent-bridge
launchctl kickstart -k "gui/$(id -u)/com.autronis.plan-avond" || bash scripts/plan-avond.sh
```

- [ ] **Step 4: Inspect DB**

```bash
cd ~/Autronis/Projects/autronis-dashboard
TOMORROW=$(date -v+1d +%Y-%m-%d)
sqlite3 -header -column data/autronis.db \
  "SELECT id, titel, start_datum, eigenaar, gemaakt_door FROM agenda_items WHERE start_datum LIKE '${TOMORROW}%' ORDER BY start_datum;"
```

Expected: rijen met `eigenaar='sem'` en `gemaakt_door='bridge'` voor morgen's blokken.

- [ ] **Step 5: Open browser**

Visit `http://localhost:3000/agenda` en navigeer naar morgen. Expected: blokken verschijnen in de Sem-lane (of Syb-lane als je dit vanaf Syb's Mac doet).

- [ ] **Step 6: Run bridge AGAIN for dedup test**

```bash
cd ~/Autronis/Projects/agent-bridge
bash scripts/plan-avond.sh
```

Re-inspect DB (Step 4). Expected: SAME count of rows for morgen (not doubled) — bridge-reset werkt.

- [ ] **Step 7: Rollback test**

Disable flag:
```bash
sqlite3 ~/Autronis/Projects/autronis-dashboard/data/autronis.db \
  "UPDATE feature_flags SET actief=0 WHERE naam='agenda_lanes_v2';"
```

Hard-reload browser. Expected: legacy render returns. Re-enable after verification.

- [ ] **Step 8: No commit needed if tests pass; otherwise fix + commit fixes**

---

## Self-Review

**Spec coverage vs plan:**
- ✅ Phase 1 agenda UI swim lanes (Task 5+6+7)
- ✅ `eigenaar` column (Task 1+2)
- ✅ `gemaaktDoor` column (Task 1+2)
- ✅ POST/GET /api/agenda accepts new fields (Task 4)
- ✅ Feature flag for rollback (Task 1+3+7)
- ✅ Bridge commit-planning sends new fields (Task 8)
- ✅ Re-run semantics via bridge-reset endpoint (Task 8)
- ✅ UitlegBlock on agenda page (Task 7)
- ⚠ `projectId` on agenda → out of scope for this plan (belongs to Plan 4: Phase 5)
- ⚠ GTM-ritme slots → Plan 4
- ⚠ Slimme Acties table → Plan 2
- ⚠ Haiku fallback-guard → Plan 3
- ⚠ On-demand overleg → Plan 5

**Placeholder scan:** no TBD / TODO / "add appropriate error handling" blocks; each task contains full code.

**Type consistency:** `eigenaar` enum matches everywhere (`sem|syb|team|vrij`); `gemaaktDoor` enum matches (`user|bridge|fallback-haiku|ai-plan-button`). `AgendaBlokProps.type` includes `"taak"` and `"claude"` beyond schema enum — this is intentional for rendering purposes (the blok can receive legacy dag-view data that has these derived types).

**Risks flagged during review:**
1. `dag-view.tsx` is 1577 lines — Task 7 Step 3 depends on locating the right JSX block. Mitigate by reading the file before editing (executor should grep for the return statement).
2. SQLite auto-migrate behavior on `ALTER TABLE ADD COLUMN` — some existing Turso deployments may already have the column from a prior manual attempt. Task 2 Step 3 adds try/catch around duplicate-column errors to keep migration idempotent.
3. `type: "afspraak"` fallback for claude/cluster blocks is lossy — UI distinguishes via `gemaaktDoor='bridge'`. Plan 4 will add richer `type` values when project-aware rendering comes in.

## Execution Notes

- **Order matters:** Tasks 1-2 (migration + schema) MUST land before any other task that touches the DB. Tasks 3-8 mostly independent; 7 depends on 5+6; 8 depends on 4.
- **Feature flag stays OFF until Task 9 passes.** Turning it on before lane rendering works means users see broken UI.
- **Bridge runs nightly 20:30** — don't run Task 8+9 while the live bridge would trigger. Either disable launchd temporarily or run after 21:00.
