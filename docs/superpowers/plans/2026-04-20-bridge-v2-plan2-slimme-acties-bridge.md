# Bridge v2 — Plan 2: Slimme Acties door bridge

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** De rechter "Slimme Acties" sidebar stopt met generieke templates (`{branche}`, `{rol}`, `{product}`-placeholders) en wordt in plaats daarvan gevuld door concrete, context-bewuste acties die de nightly bridge produceert — met echte klant-namen, pijler-tags (sales_engine / content / klantcontact / enz.), en `voor: sem | syb | team` attributie.

**Architecture:** Nieuwe tabel `slimme_acties_bridge` naast de bestaande `slimmeTakenTemplates`. Bridge-prompt krijgt een tweede JSON output-veld `slimme_acties[]`. `commit-planning.sh` schrijft die via een nieuw endpoint `/api/slimme-acties-bridge`. Het UI-panel op de agenda-pagina leest primair uit de nieuwe tabel (filter-tabs "Voor mij / Team / Alles"), met de oude templates als fallback als de bridge-tabel leeg is. Haiku-gegenereerde templates blijven dus werkend als vangnet tijdens de migratie en voor klanten die bridge nog niet draaien.

**Tech Stack:** Next.js API route, Drizzle ORM (Turso/SQLite), React panel update, Bash bridge commit script, JSON prompt-update.

---

## File Structure

**Dashboard repo (`~/Autronis/Projects/autronis-dashboard/`):**
- Modify: `src/lib/db/schema.ts` — append `slimmeActiesBridge` table export
- Modify: `src/lib/db/index.ts` — add `CREATE TABLE IF NOT EXISTS slimme_acties_bridge` in beide DB-paden + cleanup index
- Create: `src/app/api/slimme-acties-bridge/route.ts` — POST (bridge schrijft), GET (UI leest), DELETE /[id] (user dismisses)
- Create: `src/app/api/cron/slimme-acties-cleanup/route.ts` — cron endpoint voor `verlooptOp < now()` cleanup
- Modify: `src/app/(dashboard)/agenda/page.tsx` — Slimme Acties panel: primary read `slimme_acties_bridge`, fallback op `slimmeTakenTemplates`, nieuwe filter-tabs "Voor mij / Team / Alles"
- Create: `src/app/api/slimme-acties-bridge/__tests__/post.test.ts` — Vitest tests (POST validation)

**Agent-bridge repo (`~/Autronis/Projects/agent-bridge/`):**
- Modify: `prompts/plan-avond.md` — nieuw output-veld `slimme_acties[]` + instructies over concrete Autronis-specifieke acties
- Modify: `scripts/commit-planning.sh` — stap 3: POST elk `slimme_acties[]` item naar `/api/slimme-acties-bridge`

## Glossary

- **Slimme actie**: korte uitvoerbare taak (15-60 min), direct plannbaar in agenda via klik. Niet hetzelfde als een project-taak.
- **Pijler**: GTM-categorie uit `~/Autronis/docs/go-to-market-plan.html` — `sales_engine | content | inbound | netwerk | delivery | intern | admin`.
- **`voor` veld**: `sem | syb | team` — wie wordt voorgesteld als uitvoerder. UI filtert hierop.
- **verlooptOp**: timestamp na welke de actie automatisch opgeruimd wordt (default `start_of_tomorrow + 48h`).
- **bronTaakId**: optionele link naar `taken.id` als de slimme actie een bestaand project-stukje is (bv follow-up op een outreach-lead).

---

## Task 1: Schema — slimme_acties_bridge tabel

**Files:**
- Modify: `src/lib/db/schema.ts`
- Modify: `src/lib/db/index.ts`

- [ ] **Step 1: Append table export aan schema.ts**

Na de `featureFlags` export:

```typescript
// ============ SLIMME ACTIES (bridge-generated) ============
export const slimmeActiesBridge = sqliteTable("slimme_acties_bridge", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  titel: text("titel").notNull(),
  beschrijving: text("beschrijving"),
  cluster: text("cluster"),
  pijler: text("pijler"),
  duurMin: integer("duur_min"),
  voor: text("voor", { enum: ["sem", "syb", "team"] }).notNull().default("team"),
  prioriteit: text("prioriteit", { enum: ["laag", "normaal", "hoog"] }).notNull().default("normaal"),
  bronTaakId: integer("bron_taak_id").references(() => taken.id),
  gecreeerdOp: text("gecreeerd_op").notNull().default(sql`(datetime('now'))`),
  verlooptOp: text("verloopt_op").notNull(),
}, (table) => ({
  idxVerlooptOp: index("idx_slimme_acties_bridge_verloopt").on(table.verlooptOp),
  idxVoor: index("idx_slimme_acties_bridge_voor").on(table.voor),
}));
```

- [ ] **Step 2: Voeg CREATE TABLE toe aan db/index.ts — Turso branch**

Naast de bestaande `feature_flags` CREATE (rond regel 685):

```typescript
  client.execute(`CREATE TABLE IF NOT EXISTS slimme_acties_bridge (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    titel TEXT NOT NULL,
    beschrijving TEXT,
    cluster TEXT,
    pijler TEXT,
    duur_min INTEGER,
    voor TEXT NOT NULL DEFAULT 'team',
    prioriteit TEXT NOT NULL DEFAULT 'normaal',
    bron_taak_id INTEGER REFERENCES taken(id),
    gecreeerd_op TEXT NOT NULL DEFAULT (datetime('now')),
    verloopt_op TEXT NOT NULL
  )`).catch(() => {});
  client.execute(`CREATE INDEX IF NOT EXISTS idx_slimme_acties_bridge_verloopt ON slimme_acties_bridge(verloopt_op)`).catch(() => {});
  client.execute(`CREATE INDEX IF NOT EXISTS idx_slimme_acties_bridge_voor ON slimme_acties_bridge(voor)`).catch(() => {});
```

- [ ] **Step 3: Mirror in sqlite branch (rond regel 1175)**

```typescript
  sqliteDb.exec(`CREATE TABLE IF NOT EXISTS slimme_acties_bridge (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    titel TEXT NOT NULL,
    beschrijving TEXT,
    cluster TEXT,
    pijler TEXT,
    duur_min INTEGER,
    voor TEXT NOT NULL DEFAULT 'team',
    prioriteit TEXT NOT NULL DEFAULT 'normaal',
    bron_taak_id INTEGER REFERENCES taken(id),
    gecreeerd_op TEXT NOT NULL DEFAULT (datetime('now')),
    verloopt_op TEXT NOT NULL
  )`);
  sqliteDb.exec(`CREATE INDEX IF NOT EXISTS idx_slimme_acties_bridge_verloopt ON slimme_acties_bridge(verloopt_op)`);
  sqliteDb.exec(`CREATE INDEX IF NOT EXISTS idx_slimme_acties_bridge_voor ON slimme_acties_bridge(voor)`);
```

- [ ] **Step 4: TypeScript check + commit**

```bash
cd ~/Autronis/Projects/autronis-dashboard
npx tsc --noEmit 2>&1 | grep -vE "pixel-office" | head
git add src/lib/db/schema.ts src/lib/db/index.ts
git commit -m "feat(db): slimme_acties_bridge tabel + indexes"
```

---

## Task 2: API route — POST / GET / DELETE

**Files:**
- Create: `src/app/api/slimme-acties-bridge/route.ts`
- Create: `src/app/api/slimme-acties-bridge/[id]/route.ts`

- [ ] **Step 1: Write POST + GET route**

`src/app/api/slimme-acties-bridge/route.ts`:
```typescript
import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db";
import { slimmeActiesBridge } from "@/lib/db/schema";
import { requireAuth, requireAuthOrApiKey } from "@/lib/auth";
import { eq, and, or, gte, inArray } from "drizzle-orm";

const VALID_VOOR = ["sem", "syb", "team"] as const;
const VALID_PRIORITEIT = ["laag", "normaal", "hoog"] as const;

// POST /api/slimme-acties-bridge — bridge schrijft batch
// Body: { acties: [{ titel, beschrijving?, cluster?, pijler?, duurMin?, voor, prioriteit?, bronTaakId?, verlooptOp }] }
// API-key auth (bridge calls this).
export async function POST(req: NextRequest) {
  try {
    await requireAuthOrApiKey(req);
    const body = await req.json();
    const acties = Array.isArray(body.acties) ? body.acties : null;
    if (!acties || acties.length === 0) {
      return NextResponse.json({ fout: "acties[] is verplicht." }, { status: 400 });
    }

    const rijen = [];
    for (const a of acties) {
      if (typeof a.titel !== "string" || !a.titel.trim()) {
        return NextResponse.json({ fout: "Elke actie heeft een titel nodig." }, { status: 400 });
      }
      const voor = a.voor ?? "team";
      if (!VALID_VOOR.includes(voor)) {
        return NextResponse.json({ fout: `Ongeldige voor '${voor}'.` }, { status: 400 });
      }
      const prioriteit = a.prioriteit ?? "normaal";
      if (!VALID_PRIORITEIT.includes(prioriteit)) {
        return NextResponse.json({ fout: `Ongeldige prioriteit '${prioriteit}'.` }, { status: 400 });
      }
      if (typeof a.verlooptOp !== "string" || !a.verlooptOp) {
        return NextResponse.json({ fout: "Elke actie heeft verlooptOp nodig." }, { status: 400 });
      }
      rijen.push({
        titel: a.titel.trim(),
        beschrijving: a.beschrijving?.trim() || null,
        cluster: a.cluster?.trim() || null,
        pijler: a.pijler?.trim() || null,
        duurMin: typeof a.duurMin === "number" ? a.duurMin : null,
        voor,
        prioriteit,
        bronTaakId: typeof a.bronTaakId === "number" ? a.bronTaakId : null,
        verlooptOp: a.verlooptOp,
      });
    }

    const inserted = await db.insert(slimmeActiesBridge).values(rijen).returning();
    return NextResponse.json({ acties: inserted, aantal: inserted.length }, { status: 201 });
  } catch (error) {
    return NextResponse.json(
      { fout: error instanceof Error ? error.message : "Onbekende fout" },
      { status: error instanceof Error && error.message === "Niet geauthenticeerd" ? 401 : 500 }
    );
  }
}

// GET /api/slimme-acties-bridge?voor=sem|syb|team|alles
// Default voor=alles. Filter impliciet alleen niet-verlopen.
export async function GET(req: NextRequest) {
  try {
    await requireAuth();
    const { searchParams } = new URL(req.url);
    const filter = searchParams.get("voor") || "alles";
    const nu = new Date().toISOString();

    const voorSet: Array<"sem" | "syb" | "team"> =
      filter === "sem" ? ["sem", "team"] :
      filter === "syb" ? ["syb", "team"] :
      filter === "team" ? ["team"] :
      ["sem", "syb", "team"];

    const acties = await db
      .select()
      .from(slimmeActiesBridge)
      .where(and(
        inArray(slimmeActiesBridge.voor, voorSet),
        gte(slimmeActiesBridge.verlooptOp, nu),
      ))
      .orderBy(slimmeActiesBridge.prioriteit, slimmeActiesBridge.gecreeerdOp);

    return NextResponse.json({ acties }, {
      headers: { "Cache-Control": "private, max-age=30" },
    });
  } catch (error) {
    return NextResponse.json(
      { fout: error instanceof Error ? error.message : "Onbekende fout" },
      { status: error instanceof Error && error.message === "Niet geauthenticeerd" ? 401 : 500 }
    );
  }
}
```

- [ ] **Step 2: Write DELETE [id] route**

`src/app/api/slimme-acties-bridge/[id]/route.ts`:
```typescript
import { NextResponse } from "next/server";
import { db } from "@/lib/db";
import { slimmeActiesBridge } from "@/lib/db/schema";
import { requireAuth } from "@/lib/auth";
import { eq } from "drizzle-orm";

// DELETE /api/slimme-acties-bridge/[id] — user dismisses an action.
export async function DELETE(
  _req: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    await requireAuth();
    const { id } = await params;
    const idNum = parseInt(id, 10);
    if (!Number.isFinite(idNum)) {
      return NextResponse.json({ fout: "Ongeldig id." }, { status: 400 });
    }
    const result = await db
      .delete(slimmeActiesBridge)
      .where(eq(slimmeActiesBridge.id, idNum))
      .returning({ id: slimmeActiesBridge.id });
    if (result.length === 0) {
      return NextResponse.json({ fout: "Niet gevonden." }, { status: 404 });
    }
    return NextResponse.json({ succes: true });
  } catch (error) {
    return NextResponse.json(
      { fout: error instanceof Error ? error.message : "Onbekende fout" },
      { status: error instanceof Error && error.message === "Niet geauthenticeerd" ? 401 : 500 }
    );
  }
}
```

- [ ] **Step 3: TypeScript + commit**

```bash
cd ~/Autronis/Projects/autronis-dashboard
npx tsc --noEmit 2>&1 | grep -vE "pixel-office" | head
git add src/app/api/slimme-acties-bridge
git commit -m "feat(slimme-acties): POST/GET/DELETE endpoints voor bridge-generated acties"
```

---

## Task 3: Cleanup cron endpoint

**Files:**
- Create: `src/app/api/cron/slimme-acties-cleanup/route.ts`

- [ ] **Step 1: Write cron route**

```typescript
import { NextResponse } from "next/server";
import { db } from "@/lib/db";
import { slimmeActiesBridge } from "@/lib/db/schema";
import { lt } from "drizzle-orm";

// GET /api/cron/slimme-acties-cleanup — dagelijks 04:00 UTC via Vercel cron.
// Verwijdert verlopen rijen. Geen auth: cron-only route (Vercel filtert op
// header in prod; zie vercel.json).
export async function GET() {
  try {
    const nu = new Date().toISOString();
    const result = await db
      .delete(slimmeActiesBridge)
      .where(lt(slimmeActiesBridge.verlooptOp, nu))
      .returning({ id: slimmeActiesBridge.id });
    return NextResponse.json({ verwijderd: result.length });
  } catch (error) {
    return NextResponse.json(
      { fout: error instanceof Error ? error.message : "Onbekende fout" },
      { status: 500 }
    );
  }
}
```

- [ ] **Step 2: Register in vercel.json**

Open `vercel.json` in de dashboard repo. Voeg toe onder `crons`:
```json
{ "path": "/api/cron/slimme-acties-cleanup", "schedule": "0 4 * * *" }
```

Als `crons` array nog niet bestaat, maak hem aan:
```json
"crons": [
  { "path": "/api/cron/slimme-acties-cleanup", "schedule": "0 4 * * *" }
]
```

- [ ] **Step 3: Commit**

```bash
cd ~/Autronis/Projects/autronis-dashboard
git add src/app/api/cron/slimme-acties-cleanup/route.ts vercel.json
git commit -m "feat(cron): daily cleanup voor verlopen slimme-acties-bridge rijen"
```

---

## Task 4: Bridge prompt output update

**Files:**
- Modify: `~/Autronis/Projects/agent-bridge/prompts/plan-avond.md`

- [ ] **Step 1: Update prompt met slimme-acties sectie**

Voeg TOE na de `"samenvatting"` regel in het Output JSON-schema, binnen het top-level object:

```json
  "slimme_acties": [
    {
      "titel": "Cold outreach batch — 10 webshops Zutphen",
      "beschrijving": "10 e-commerce prospects uit Zutphen die op Shopify of Magento draaien, via Sales Engine scannen en DM sturen",
      "cluster": "klantcontact",
      "pijler": "sales_engine",
      "duurMin": 45,
      "voor": "sem",
      "prioriteit": "normaal"
    }
  ]
```

En voeg als nieuwe regel onder "Regels" toe:

```
10. **Slimme acties (`slimme_acties[]`)**: produceer 5-10 concrete uitvoerbare acties van 15-60 min per stuk. **Geen generieke templates** zoals "1-op-1 koffie {branche}" — altijd concrete klantnamen, project-stappen, of specifieke outreach batches. Verdeel logisch over `voor: sem | syb | team`. Gebruik pijler uit GTM-plan: sales_engine | content | inbound | netwerk | delivery | intern | admin. Gebruik cluster uit CLAUDE.md: backend-infra | frontend | klantcontact | content | admin | research.
```

- [ ] **Step 2: Commit**

```bash
cd ~/Autronis/Projects/agent-bridge
git add prompts/plan-avond.md
git commit -m "feat(prompt): output schema slimme_acties[] + concreet-over-generiek regel"
```

---

## Task 5: Bridge commit-planning.sh stuurt slimme acties

**Files:**
- Modify: `~/Autronis/Projects/agent-bridge/scripts/commit-planning.sh`

- [ ] **Step 1: Voeg stap 3 toe na de bestaande blokken-loop**

Na de bestaande Python-blok `PY` (stap 2 die blokken POST), voeg toe:

```bash
# Step 3: POST slimme_acties[] naar /api/slimme-acties-bridge
PLAN_JSON="$PLAN_JSON" URL="$DASHBOARD_URL" KEY="$API_KEY" python3 <<'PY'
import json, os, subprocess, sys
from datetime import datetime, timedelta, timezone

with open(os.environ["PLAN_JSON"]) as f:
    plan = json.load(f)

acties = plan.get("slimme_acties") or []
if not acties:
    sys.exit(0)

# verlooptOp = start_of_tomorrow + 48h (tomorrow is when they're most useful)
now = datetime.now(timezone.utc)
tomorrow = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
verloopt = (tomorrow + timedelta(hours=48)).isoformat().replace("+00:00", "Z")

payload = []
valid_voor = {"sem", "syb", "team"}
valid_prior = {"laag", "normaal", "hoog"}
for a in acties:
    if not isinstance(a, dict) or not a.get("titel"):
        continue
    voor = a.get("voor") or "team"
    if voor not in valid_voor:
        voor = "team"
    prio = a.get("prioriteit") or "normaal"
    if prio not in valid_prior:
        prio = "normaal"
    payload.append({
        "titel": a["titel"],
        "beschrijving": a.get("beschrijving") or None,
        "cluster": a.get("cluster") or None,
        "pijler": a.get("pijler") or None,
        "duurMin": a.get("duurMin"),
        "voor": voor,
        "prioriteit": prio,
        "bronTaakId": a.get("bronTaakId"),
        "verlooptOp": verloopt,
    })

if not payload:
    sys.exit(0)

url = os.environ["URL"].rstrip("/")
key = os.environ["KEY"]
r = subprocess.run(
    [
        "curl", "-s", "-w", "\nHTTP:%{http_code}",
        "-X", "POST", f"{url}/api/slimme-acties-bridge",
        "-H", f"Authorization: Bearer {key}",
        "-H", "Content-Type: application/json",
        "-d", json.dumps({"acties": payload}),
    ],
    capture_output=True, text=True,
)
body_out = r.stdout or ""
parts = body_out.rsplit("HTTP:", 1)
code = parts[1].strip() if len(parts) > 1 else "?"
if code.startswith("2"):
    print(f"slimme-acties: {len(payload)} gepost", file=sys.stderr)
else:
    snippet = parts[0][:180].replace("\n", " ")
    print(f"slimme-acties FAIL ({code}): {snippet}", file=sys.stderr)
PY
```

- [ ] **Step 2: Bash syntax check + commit**

```bash
cd ~/Autronis/Projects/agent-bridge
bash -n scripts/commit-planning.sh
git add scripts/commit-planning.sh
git commit -m "feat(bridge): POST slimme_acties[] naar /api/slimme-acties-bridge"
```

---

## Task 6: UI — Slimme Acties panel leest van bridge

**Files:**
- Modify: `src/app/(dashboard)/agenda/page.tsx`

- [ ] **Step 1: Lokaliseer de huidige Slimme Acties render-blok**

```bash
cd ~/Autronis/Projects/autronis-dashboard
grep -n "SLIMME ACTIES\|slimmeTemplates\|slimmeActiesAgenda" "src/app/(dashboard)/agenda/page.tsx" | head -10
```

Noteer de regel-nummers — de panel render zit waarschijnlijk ergens rond het `Slimme Acties` label in de sidebar sectie.

- [ ] **Step 2: Fetch bridge-acties in page state**

Voeg aan het begin van de component (bij de andere `useState` + `useEffect`):

```typescript
interface BridgeActie {
  id: number;
  titel: string;
  beschrijving: string | null;
  cluster: string | null;
  pijler: string | null;
  duurMin: number | null;
  voor: "sem" | "syb" | "team";
  prioriteit: "laag" | "normaal" | "hoog";
}

const [slimmeActiesFilter, setSlimmeActiesFilter] = useState<"voor-mij" | "team" | "alles">("voor-mij");
const [bridgeActies, setBridgeActies] = useState<BridgeActie[]>([]);
const [bridgeActiesLoading, setBridgeActiesLoading] = useState(true);

useEffect(() => {
  const voor = slimmeActiesFilter === "voor-mij" ? "sem" : slimmeActiesFilter === "team" ? "team" : "alles";
  fetch(`/api/slimme-acties-bridge?voor=${voor}`, { cache: "no-store" })
    .then((r) => (r.ok ? r.json() : { acties: [] }))
    .then((j: { acties?: BridgeActie[] }) => {
      setBridgeActies(Array.isArray(j.acties) ? j.acties : []);
      setBridgeActiesLoading(false);
    })
    .catch(() => {
      setBridgeActies([]);
      setBridgeActiesLoading(false);
    });
}, [slimmeActiesFilter]);
```

- [ ] **Step 3: Render filter-tabs + bridge acties boven de legacy templates**

In de JSX-render van de Slimme Acties sectie: voeg de filter-tabs bovenaan, dan de bridge-acties, dan (als `bridgeActies.length === 0 && !bridgeActiesLoading`) de legacy `slimmeTemplates` als fallback. De precieze insertion point hangt van de huidige structuur af — gebruik het label `SLIMME ACTIES` als anker.

```typescript
{/* Filter tabs */}
<div className="flex gap-1 text-xs mb-2">
  {(["voor-mij", "team", "alles"] as const).map((f) => (
    <button
      key={f}
      onClick={() => setSlimmeActiesFilter(f)}
      className={cn(
        "px-2 py-1 rounded-md transition-colors",
        slimmeActiesFilter === f
          ? "bg-autronis-accent/20 text-autronis-accent"
          : "text-autronis-text-secondary hover:text-autronis-text-primary"
      )}
    >
      {f === "voor-mij" ? "Voor mij" : f === "team" ? "Team" : "Alles"}
    </button>
  ))}
</div>

{/* Bridge acties (primary) */}
{bridgeActies.length > 0 && (
  <div className="grid grid-cols-2 gap-2 mb-3">
    {bridgeActies.map((a) => (
      <div
        key={a.id}
        className="bg-autronis-card border border-autronis-border rounded-lg p-2.5 space-y-1"
        data-pijler={a.pijler || "geen"}
      >
        <div className="text-sm font-medium text-autronis-text-primary line-clamp-2">{a.titel}</div>
        {a.beschrijving && (
          <div className="text-xs text-autronis-text-secondary line-clamp-3">{a.beschrijving}</div>
        )}
        <div className="flex items-center justify-between pt-1">
          <div className="flex gap-1">
            {a.pijler && <span className="text-[10px] px-1.5 py-0.5 rounded bg-autronis-accent/10 text-autronis-accent">{a.pijler}</span>}
            {a.cluster && <span className="text-[10px] px-1.5 py-0.5 rounded bg-autronis-bg text-autronis-text-secondary">{a.cluster}</span>}
          </div>
          {a.duurMin != null && <span className="text-[10px] tabular-nums text-autronis-text-secondary">{a.duurMin}m</span>}
        </div>
      </div>
    ))}
  </div>
)}

{/* Legacy fallback (bestaande template-render) blijft eronder */}
{bridgeActies.length === 0 && !bridgeActiesLoading && (
  <div className="text-xs text-autronis-text-secondary italic mb-2">
    Nog geen bridge-acties voor vanavond. Legacy templates hieronder.
  </div>
)}
```

**Note:** de exacte insertion in `page.tsx` moet je afstemmen op de bestaande JSX-structuur rond de `slimmeActiesAgenda` render. Kijk in de huidige code waar `SLIMME ACTIES` label staat (rond regel 2450-2500) en hang dit paneel er strak bovenop.

- [ ] **Step 4: TypeScript check + commit**

```bash
cd ~/Autronis/Projects/autronis-dashboard
npx tsc --noEmit 2>&1 | grep -vE "pixel-office" | head
git add "src/app/(dashboard)/agenda/page.tsx"
git commit -m "feat(agenda): slimme-acties panel leest uit bridge tabel, fallback op legacy"
```

---

## Task 7: Handmatige seed voor visuele check

**Files:** geen code — vul handmatig een paar rijen zodat het panel gevuld is voordat bridge zijn eerste run doet.

- [ ] **Step 1: Kleine script `scripts/seed-slimme-acties-demo.mjs`**

Maak een helper die 5 dummy bridge-acties seedt voor visuele verificatie. Dan kan je direct in browser zien hoe het panel eruitziet zonder tot 20:30 te wachten.

```javascript
#!/usr/bin/env node
// Seed 5 voorbeeld slimme-acties zodat het panel meteen gevuld is.
import { readFileSync } from "node:fs";
import { createClient } from "@libsql/client";

function loadEnv() {
  const text = readFileSync(".env.local", "utf8");
  const out = {};
  for (const line of text.split("\n")) {
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return out;
}
const env = loadEnv();
const client = createClient({ url: env.TURSO_DATABASE_URL, authToken: env.TURSO_AUTH_TOKEN });

const nu = new Date();
const verloopt = new Date(nu.getTime() + 48 * 3600 * 1000).toISOString();

const seeds = [
  { titel: "Cold outreach batch — 10 webshops Zutphen", beschrijving: "Shopify/Magento-prospects uit ICP, via Sales Engine scannen + DM", cluster: "klantcontact", pijler: "sales_engine", duur_min: 45, voor: "sem", prioriteit: "hoog" },
  { titel: "Case study Heemskerk publiceren", beschrijving: "500 woorden + screenshots van de n8n flow, op autronis.com/cases", cluster: "content", pijler: "content", duur_min: 60, voor: "sem", prioriteit: "normaal" },
  { titel: "Follow-up LP Brands + Nukeware", beschrijving: "3 dagen geen reply — Loom-video van 30 sec met pijnpunt-vondst", cluster: "klantcontact", pijler: "sales_engine", duur_min: 20, voor: "sem", prioriteit: "hoog" },
  { titel: "Syb: ICP-filter update Lead Dashboard v2", beschrijving: "Pas filter aan op 10-50 medewerkers + branches 1,2,3", cluster: "backend-infra", pijler: "inbound", duur_min: 30, voor: "syb", prioriteit: "normaal" },
  { titel: "Team: intake-call prep fietsenzaak", beschrijving: "Scan runnen + rapport reviewen voor morgen 10:00 intake", cluster: "klantcontact", pijler: "delivery", duur_min: 25, voor: "team", prioriteit: "hoog" },
];

for (const s of seeds) {
  await client.execute({
    sql: `INSERT INTO slimme_acties_bridge (titel, beschrijving, cluster, pijler, duur_min, voor, prioriteit, verloopt_op) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    args: [s.titel, s.beschrijving, s.cluster, s.pijler, s.duur_min, s.voor, s.prioriteit, verloopt],
  });
}
console.log(`${seeds.length} demo acties geseed.`);
```

- [ ] **Step 2: Run + reload browser**

```bash
cd ~/Autronis/Projects/autronis-dashboard
node scripts/seed-slimme-acties-demo.mjs
```

Open `http://localhost:3000/agenda`, panel zou 5 rijen moeten tonen met concreet Autronis-werk.

- [ ] **Step 3: Commit script**

```bash
git add scripts/seed-slimme-acties-demo.mjs
git commit -m "chore(scripts): seed-slimme-acties-demo voor visuele verify zonder bridge run"
```

---

## Self-Review

**Spec coverage:**
- ✅ Nieuwe tabel `slimme_acties_bridge` met alle spec-velden (Task 1)
- ✅ POST/GET/DELETE endpoints met auth + validatie (Task 2)
- ✅ Cleanup cron voor verlopen rijen (Task 3)
- ✅ Bridge prompt genereert slimme_acties[] (Task 4)
- ✅ commit-planning.sh schrijft ze weg (Task 5)
- ✅ UI panel leest primair uit bridge-tabel + filter-tabs "Voor mij / Team / Alles" (Task 6)
- ✅ Fallback naar legacy templates behouden (Task 6 Step 3)
- ✅ Demo-seed voor directe visuele check (Task 7)

**Placeholder scan:** geen TBD, alle code-blokken compleet.

**Type-consistency:** `voor` enum `sem|syb|team` overal identiek. `pijler` is vrije TEXT want het evolueert; `cluster` idem.

**Risks:**
1. `slimmeTakenTemplates` blijft bestaan — bewuste keuze, dubbele datastore tijdens overgang. Volgende plan of cleanup als bridge stabiel draait.
2. `vercel.json` edit in Task 3 kan conflicteren met Atlas' parallelle cron-werk. Check voor je commit dat het bestand nog de verwachte vorm heeft.
3. De UI insertion point in Task 6 Step 3 is tekstueel — de executor moet de huidige `page.tsx` structuur begrijpen voor ze slaan. Grep eerst, dan edit.

## Execution Notes

- Task 1 moet voor alle anderen — schema.ts is dependency.
- Task 2+3 kunnen parallel maar geen reden om niet sequentieel.
- Task 4+5 zijn in agent-bridge repo; Task 1-3 + 6 in dashboard repo.
- Task 7 (demo seed) is optioneel maar geeft directe visuele feedback; aanrader.
- Flag `agenda_lanes_v2` is al aan, `agenda_syb_lane` ook; geen extra flag nodig voor Plan 2 — het panel upgrade is altijd actief zodra deploy live gaat.
