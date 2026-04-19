# Bridge v2 — Plan 4: Klant-project dimensie + GTM-ritme slots

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Agenda-blokken weten aan welke klant ze horen (project-accent-kleur + klant-naam bovenin het blok), en de bridge plant om vaste GTM-ritme-slots heen (Sales Engine batch 09:00–10:30 werkdagen, engagement-window 16:30, content zaterdag 10:00). Plus: "Project Focus Mode" om een dag aan één klant te wijden.

**Architecture:** 
- Schema: `projectId` kolom op `agenda_items` + nieuwe tabel `gtm_ritme_slots`
- `AgendaBlok` component rendert project-naam en kleur uit een stabiele-hash helper
- Bridge fetch-context laadt actieve klanten + GTM-slots, prompt krijgt instructie om ritme te respecteren
- Nieuwe `/api/projecten/[id]/focus-dag` endpoint voor focus-mode

**Tech Stack:** Drizzle schema, Next.js API, React component update, Bash bridge script, prompt uitbreiding.

---

## File Structure

**Dashboard repo:**
- Modify: `src/lib/db/schema.ts` — `projectId` op agendaItems, nieuwe `gtmRitmeSlots` export
- Modify: `src/lib/db/index.ts` — CREATE voor `gtm_ritme_slots` + auto-migrate voor agendaItems.projectId + seed GTM-defaults
- Modify: `src/app/api/agenda/route.ts` — POST/GET geven projectId door
- Modify: `src/hooks/queries/use-agenda.ts` — type `AgendaItem` krijgt `projectId` + `projectNaam`
- Modify: `src/app/(dashboard)/agenda/dag-view.tsx` — laneItems mapping vult projectNaam + projectKleur uit hash
- Modify: `src/app/(dashboard)/agenda/agenda-blok.tsx` — al klaar voor project kleur (props bestaan)
- Create: `src/lib/klant-kleuren.ts` — stabiele hash van projectId → één van 10 vaste palet-kleuren
- Create: `src/app/api/gtm-ritme/route.ts` — GET/POST/DELETE GTM ritme slots
- Create: `src/app/api/projecten/[id]/focus-dag/route.ts` — POST { datum } → triggers bridge to focus morgen

**Agent-bridge repo:**
- Modify: `scripts/fetch-context.sh` — extra fetch: actieve klanten + GTM-slots
- Modify: `prompts/plan-avond.md` — instructie om GTM-slots te respecteren + project-context gebruiken
- Modify: `scripts/commit-planning.sh` — blok body krijgt `projectId` veld

---

## Task 1: Schema + DB bootstrap

**Files:**
- Modify: `src/lib/db/schema.ts`
- Modify: `src/lib/db/index.ts`

- [ ] **Step 1: Voeg `projectId` toe aan agendaItems in schema.ts**

In de `agendaItems` definitie (rond regel 328), voeg toe na `gemaaktDoor`:
```typescript
  projectId: integer("project_id").references(() => projecten.id),
```

- [ ] **Step 2: Append `gtmRitmeSlots` export aan schema.ts**

```typescript
// ============ GTM RITME SLOTS ============
// Vaste dagelijkse/wekelijkse slots die de bridge moet respecteren als
// "protected time" voor GTM-pijlers (Sales Engine batch, content, etc.).
// Niet bindend — bridge kan afwijken als urgentie hoger is.
export const gtmRitmeSlots = sqliteTable("gtm_ritme_slots", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  gebruiker: text("gebruiker", { enum: ["sem", "syb", "team"] }).notNull(),
  pijler: text("pijler").notNull(),
  label: text("label").notNull(),
  startTijd: text("start_tijd").notNull(),
  eindTijd: text("eind_tijd").notNull(),
  dagenVanWeek: text("dagen_van_week").notNull(),
  actief: integer("actief").notNull().default(1),
  aangemaaktOp: text("aangemaakt_op").notNull().default(sql`(datetime('now'))`),
});
```

- [ ] **Step 3: db/index.ts — CREATE + seed voor Turso branch**

Na de slimme_acties_bridge INSERT regel, voeg toe:
```typescript
  client.execute(`CREATE TABLE IF NOT EXISTS gtm_ritme_slots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    gebruiker TEXT NOT NULL,
    pijler TEXT NOT NULL,
    label TEXT NOT NULL,
    start_tijd TEXT NOT NULL,
    eind_tijd TEXT NOT NULL,
    dagen_van_week TEXT NOT NULL,
    actief INTEGER NOT NULL DEFAULT 1,
    aangemaakt_op TEXT NOT NULL DEFAULT (datetime('now'))
  )`).catch(() => {});

  // Seed defaults (one-time, ON CONFLICT DO NOTHING op unique combo werkt
  // niet zonder explicit unique index — gebruik een idempotency helper check)
  client.execute(`INSERT INTO gtm_ritme_slots (gebruiker, pijler, label, start_tijd, eind_tijd, dagen_van_week, actief)
    SELECT 'sem', 'sales_engine', 'Sales Engine batch (10 scans + outreach)', '09:00', '10:30', '["ma","di","wo","do","vr"]', 1
    WHERE NOT EXISTS (SELECT 1 FROM gtm_ritme_slots WHERE gebruiker='sem' AND pijler='sales_engine')`).catch(() => {});
  client.execute(`INSERT INTO gtm_ritme_slots (gebruiker, pijler, label, start_tijd, eind_tijd, dagen_van_week, actief)
    SELECT 'sem', 'content', 'Content batching weekend', '10:00', '11:00', '["za"]', 1
    WHERE NOT EXISTS (SELECT 1 FROM gtm_ritme_slots WHERE gebruiker='sem' AND pijler='content')`).catch(() => {});
  client.execute(`INSERT INTO gtm_ritme_slots (gebruiker, pijler, label, start_tijd, eind_tijd, dagen_van_week, actief)
    SELECT 'team', 'netwerk', 'LinkedIn engagement window', '16:30', '17:00', '["ma","di","wo","do","vr"]', 1
    WHERE NOT EXISTS (SELECT 1 FROM gtm_ritme_slots WHERE gebruiker='team' AND pijler='netwerk')`).catch(() => {});
  client.execute(`INSERT INTO gtm_ritme_slots (gebruiker, pijler, label, start_tijd, eind_tijd, dagen_van_week, actief)
    SELECT 'syb', 'inbound', 'ICP filter Lead Dashboard v2', '09:00', '10:00', '["ma","do"]', 1
    WHERE NOT EXISTS (SELECT 1 FROM gtm_ritme_slots WHERE gebruiker='syb' AND pijler='inbound')`).catch(() => {});
```

- [ ] **Step 4: Mirror in sqlite branch (zelfde blok)**

- [ ] **Step 5: TypeScript + commit**

```bash
npx tsc --noEmit 2>&1 | grep -vE "pixel-office" | head
git add src/lib/db/schema.ts src/lib/db/index.ts
git commit -m "feat(db): projectId op agenda_items + gtm_ritme_slots tabel met seeds"
```

---

## Task 2: klant-kleuren helper

**Files:** Create `src/lib/klant-kleuren.ts`

```typescript
// Stabiele hash van projectId naar één van 10 merkvriendelijke accent-kleuren.
// Zelfde projectId krijgt altijd dezelfde kleur (geen random per render).
// Deze 10 kleuren zijn zorgvuldig gekozen voor contrast op dark background
// en onderscheidbaarheid onderling.

const PALET = [
  "#14b8a6", // teal
  "#8b5cf6", // violet
  "#f59e0b", // amber
  "#ec4899", // pink
  "#22c55e", // green
  "#f97316", // orange
  "#06b6d4", // cyan
  "#eab308", // yellow
  "#ef4444", // red
  "#a855f7", // purple
] as const;

export function klantKleur(projectId: number | null | undefined): string {
  if (projectId == null) return "#2A3538"; // neutral border
  const idx = Math.abs(projectId) % PALET.length;
  return PALET[idx];
}
```

Commit: `git add src/lib/klant-kleuren.ts && git commit -m "feat(lib): klantKleur hash helper — stabiele accent-kleur per projectId"`

---

## Task 3: API updates

**Files:**
- Modify: `src/app/api/agenda/route.ts` — POST/GET incl. projectId
- Modify: `src/hooks/queries/use-agenda.ts` — AgendaItem interface

- [ ] **Step 1: POST body accepts projectId, insert passes through**

In POST route: na eigenaar validatie:
```typescript
const projectId = typeof body.projectId === "number" ? body.projectId : null;
```
En in `.values({...})`: `projectId,`

- [ ] **Step 2: GET SELECT krijgt projectId + projectNaam**

```typescript
.select({
  ...,
  projectId: agendaItems.projectId,
  projectNaam: projecten.naam,
})
.from(agendaItems)
.leftJoin(gebruikers, eq(agendaItems.gebruikerId, gebruikers.id))
.leftJoin(projecten, eq(agendaItems.projectId, projecten.id))
```

Import `projecten` uit schema.

- [ ] **Step 3: use-agenda.ts interface**

```typescript
export interface AgendaItem {
  // ...existing
  projectId?: number | null;
  projectNaam?: string | null;
}
```

- [ ] **Step 4: tsc + commit**

---

## Task 4: UI — rendering project kleur + naam in agenda-blok

**Files:**
- Modify: `src/app/(dashboard)/agenda/dag-view.tsx` (de laneItems mapping)

- [ ] **Step 1: Import + gebruik**

```typescript
import { klantKleur } from "@/lib/klant-kleuren";
```

In de `laneItems` map (in het lanesV2 block), voeg toe:
```typescript
projectNaam: ag.projectNaam,
projectKleur: klantKleur(ag.projectId),
```

AgendaBlok component accepteert al `projectNaam` + `projectKleur` (staat in Plan 1 component).

- [ ] **Step 2: tsc + commit**

---

## Task 5: GTM ritme endpoint

**Files:** Create `src/app/api/gtm-ritme/route.ts`

```typescript
import { NextResponse } from "next/server";
import { db } from "@/lib/db";
import { gtmRitmeSlots } from "@/lib/db/schema";
import { requireAuthOrApiKey } from "@/lib/auth";
import { eq } from "drizzle-orm";

// GET /api/gtm-ritme — alle actieve slots voor bridge-context.
// Bridge fetch-context.sh roept dit aan om de ritme-info mee te sturen.
export async function GET(req: Request) {
  try {
    await requireAuthOrApiKey(req);
    const slots = await db.select().from(gtmRitmeSlots).where(eq(gtmRitmeSlots.actief, 1));
    return NextResponse.json({ slots });
  } catch (error) {
    return NextResponse.json(
      { fout: error instanceof Error ? error.message : "Onbekende fout" },
      { status: 500 }
    );
  }
}
```

Commit.

---

## Task 6: Bridge fetch-context + prompt update

**Files:**
- Modify: `~/Autronis/Projects/agent-bridge/scripts/fetch-context.sh`
- Modify: `~/Autronis/Projects/agent-bridge/prompts/plan-avond.md`

- [ ] **Step 1: fetch-context.sh extra fetches**

Na de bestaande fetches:
```bash
GTM=$(curl -s -H "Authorization: Bearer $API_KEY" "$DASHBOARD_URL/api/gtm-ritme")
```

In het Python-block dat de JSON bouwt, voeg toe: `"gtm_ritme": json.loads("""$GTM""").get("slots", []),`

- [ ] **Step 2: prompt regel toevoegen**

```
11. **GTM-ritme respecteren**: de context bevat `gtm_ritme[]` — vaste slots voor sales_engine, content, engagement. Plan klant-werk OMHEEN deze slots, niet EROVER. Vul de slots met relevante slimme acties (bv Sales Engine slot = een cold outreach batch actie).
```

- [ ] **Step 3: blok-schema krijgt `projectId`** in het Output-schema.

Commit.

---

## Task 7: commit-planning.sh stuurt projectId

**Files:**
- Modify: `~/Autronis/Projects/agent-bridge/scripts/commit-planning.sh`

In het blok-body dict, voeg toe:
```python
if b.get("projectId"):
    body["projectId"] = b["projectId"]
```

Commit.

---

## Self-Review

- ✅ Schema: agenda_items.projectId + gtm_ritme_slots (Task 1)
- ✅ UI rendert klant-kleur + naam (Tasks 2, 4)
- ✅ Bridge kent ritme-slots + plant eromheen (Task 6)
- ✅ commit-planning stuurt projectId (Task 7)
- ⚠️ Project Focus Mode endpoint uit scope verplaatst naar aparte follow-up (te veel voor één plan)
- ⚠️ UI om GTM-slots te bewerken: uit scope, kan via directe SQL voor nu
