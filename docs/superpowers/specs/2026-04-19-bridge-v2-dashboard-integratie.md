# Bridge v2 — Dashboard integratie & agenda redesign

**Datum:** 2026-04-19
**Status:** Design — wacht op review
**Project:** Atlas-Autro Planning Bridge (dashboard #48)
**Eigenaar:** team (Sem + Syb)
**Bouwt voort op:** [v1 plan](../plans/2026-04-19-atlas-autro-planning-bridge.md)

## Context

V1 (huidig plan) levert een werkende nachtelijke bridge: launchd triggert om 20:30/20:45, fetch-context → Claude headless → Discord post → `/api/agenda` commit. Werkt, maar twee observaties na de eerste week:

1. **Het dashboard zelf kan niet goed plannen.** De huidige in-app "AI plan" knop doet één Haiku-call (`src/app/api/agenda/ai-plan/route.ts`, 483 regels). Die kent alleen de taaklijst en blinde tijdregels — geen klant-uur context, geen cross-persoon verdeling, geen kwaliteitsoordeel over welke taak wanneer past. Resultaat = onrealistische blokken.
2. **De agenda-UI is onleesbaar.** Claude-sessies (paars) en handmatige taken (groen) worden in dezelfde tijd-kolom gerenderd en overlappen visueel bij botsingen. Bij een dag met veel items krijg je een stapel die niet te ontcijferen is.

V2 lost beide op door: (a) de bridge óók de "Slimme Acties" genereert die momenteel door Haiku komen, (b) de agenda-UI te herbouwen met **swim lanes per persoon**, en (c) de in-app Haiku-planner te degraderen tot fallback.

## Strategische context (waarom dit nu telt)

Autronis GTM-doelen (zie `~/Autronis/docs/go-to-market-plan.html`):
- **200 outreach/mnd** via Sales Engine (10 scans + 10 outreach per werkdag)
- **5 content posts/week** verdeeld over 5 pijlers
- **3 deals/maand** tegen einde 90-dagen-plan
- Klant-delivery-projecten duren 1–10 weken met parallelle werkstromen

De agenda moet dit ritme **zichtbaar** maken: wanneer hoort 't Sales-Engine-uur thuis, op welke dagen zit er LP Brands-delivery, wanneer content-batching. Nu is het een homp losse blokken zonder klant- of pijler-context.

Ook nieuw: Atlas en Autro **leven in elke chat** via het cross-chat observability systeem (`~/.claude/chats-active/`). Ze kennen elkaars context niet alleen 's avonds om 20:30, maar kunnen ad-hoc overleggen via `chat-requests/inbox-*`. De bridge wordt daarmee eigenlijk een **continue coordinatielaag**, niet alleen een nachtelijke batch.

## Wat ik uit de screenshots afleid (huidige agenda)

1. **Overlap-chaos** — groene (handmatig) en paarse (claude-sessie) blokken botsen visueel op dezelfde tijdslot. Titels snijden door elkaar.
2. **Claude-sessies zonder klant-label** — "Fase 1 – Website Scan & AI Analyse" is voor Autronis intern (Sales Engine), maar dat staat er niet bij. Een externe klant-blok zou hetzelfde eruit zien.
3. **Slimme Acties zijn project-loos** — "1-op-1 koffie (warm)", "Cold outreach batch", "Content kalender week plannen" zijn nuttig, maar nergens staat *voor welke pijler* of *welke klant*.
4. **Te smal, geen hierarchie** — elk blok is ~500px breed in een 1600px browser. Geen onderscheid tussen uur-lang-diep-werk-blok vs 15-min-quick-task.

## Scope

**In:**
- UI redesign agenda: twee lanes Sem/Syb met clean blokken, betere visuele hierarchie (grote blokken voor 90+ min, compact voor ≤30 min)
- `eigenaar` op agenda-items (lane), `projectId` op agenda-items (klant-accent), `pijler` op slimme acties (GTM-ritme)
- Bridge schrijft blokken én slimme acties naar dashboard, met volledige klant/project context
- Project-focus mode (een dag expliciet aan één klant wijden → bridge plant alle slots voor dat project)
- GTM-ritme slots (dagelijks 10:00 Sales Engine batch, 16:30 content engagement) worden auto-voorgesteld
- Haiku-planner `/api/agenda/ai-plan` → fallback mode
- On-demand Atlas↔Autro overleg via chat-requests inbox (ad-hoc, niet alleen 20:30)

**Uit:**
- Google Calendar sync (staat al, blijft)
- Turso coordinatie-tabel voor overleg (chat-requests inbox is al state)
- Mobiele agenda-redesign (alleen desktop)
- Multi-ronde debat tussen Atlas en Autro (één ronde nachtelijk + on-demand ping, geen meerdere heen-en-weer)
- Publieke klant-portal view (agenda blijft intern)

## Fases

### Phase 1 — Agenda UI redesign (swim lanes)

**Probleem:** huidige agenda rendert alles in één tijdkolom. Bij overlap → visuele chaos.

**Oplossing:** twee vertikale lanes naast elkaar, per persoon. Items plaatsen zich in de lane van hun `eigenaar`. Items met `eigenaar=team` spannen beide lanes. `eigenaar=vrij` → in een smalle middenkolom, nog niet gepakt.

**Componenten die raken:**
- `src/app/agenda/page.tsx` (of `src/app/components/Agenda*.tsx`) — layout van de kolom wordt grid met 2 of 3 lanes
- `AgendaItem` component — krijgt `laneIndex` prop, border-kleur per eigenaar (sem=blauw, syb=groen, team=paars, vrij=grijs)
- Tijdlijn-ruler staat links, shared voor beide lanes (één scroll)
- Claude-sessie blok (nu paars) en handmatig blok (nu groen) krijgen zelfde stijl — onderscheid door `type`-badge bovenin (claude/handmatig/meeting) ipv verschillende achtergrond

**Visueel:**
```
 tijd  │ Sem                        │ Syb                       │ vrij
 ─────┼────────────────────────────┼───────────────────────────┼─────────────
 09:00 │ ▌ LP BRANDS   ┐            │ ▌ AUTRONIS  ┐             │
       │ ▌ Demo voor-  │ 90 min     │ ▌ Lead DB   │ 60 min      │
       │ ▌ bereiden    │ [claude]   │ ▌ ICP filter│ [handmatig] │
       │ └────────────┘             │ └──────────┘             │
 10:30 │ ▌ AUTRONIS GTM ━━━━━━ 60m │ ▌ NUKEWARE ━━━━━━ 45m    │ ▌ Fietsen-
       │   Sales Engine batch       │   n8n workflow bouwen     │ ▌ zaak
       │   (10 scans + outreach)    │                           │ ▌ onboard
 12:00 │ ═══════ Team: Intake meeting Bakkerij Jansen ═══════════════════════
 12:30 │ ─────── lunch (visueel grijs, doorloopt beide lanes) ────────────────
 13:30 │ ▌ LP BRANDS   ┐            │                          │
       │ ▌ Edge func   │ 75 min     │                          │
       │ ▌ auth flow   │ [claude]   │                          │
       │ └────────────┘             │                          │
```

**Visuele elementen per blok:**
- **Linker accent-rand (4px)** met klant/project kleur → seinpost voor klant-context (zichtbaar in peripheral vision)
- **Klant/project-naam bovenin** (SMALL CAPS, 11px, accent-kleur) — ALTIJD zichtbaar, nooit afgekapt
- **Blok-titel** (14px, normale tekst) — kan wel wrappen naar 2 regels
- **Type-badge rechtsonder** (claude / handmatig / meeting / batch) — 10px pill
- **Duur rechtsboven** — "90m" / "2u" — tabular nums
- **Blok-hoogte = proportioneel aan duur** (30 min = 48px, 60 min = 96px, 90 min = 144px) — oog leert snel "lang blok = diep werk"
- Overlap binnen één lane = **verboden** (API-validation rejects; UI highlights rood als user handmatig zou proberen)
- Lunch 12:30–13:30 = grijze overlay die beide lanes overspant (niet als blok, maar als background-stripe)

**UitlegBlock** bovenaan pagina (per CLAUDE.md feedback memory): korte tekst over lanes + hoe slepen werkt + wat de kleurcodes betekenen (persistent collapse per user).

### Phase 2 — Bridge schrijft naar agenda met lane awareness

**Probleem:** v1 commit-planning.sh POST naar `/api/agenda` zonder `eigenaar`. Atlas' en Autro's blokken landen door elkaar.

**Oplossing:**
- `/api/agenda` POST body accepteert `eigenaar` (sem|syb|team|vrij) — default = user van de API key
- `agenda` tabel krijgt `eigenaar` kolom (migration) — default 'vrij' voor bestaande rows
- Bridge's plan-JSON (uit `prompts/plan-avond.md`) krijgt per blok een `eigenaar` veld, default = de user die plant
- Team-taken die Atlas+Autro samen afstemmen krijgen `eigenaar='team'`

**Schema migration:**
```sql
ALTER TABLE agenda ADD COLUMN IF NOT EXISTS eigenaar TEXT NOT NULL DEFAULT 'vrij';
CREATE INDEX IF NOT EXISTS idx_agenda_eigenaar_datum ON agenda(eigenaar, startDatum);
```

**Prompt update** (`prompts/plan-avond.md`): blok-schema krijgt `"eigenaar"` veld, Claude moet 't expliciet zetten.

### Phase 3 — Slimme Acties vervangen door bridge

**Probleem:** huidige Slimme Acties worden door Haiku-call gegenereerd (`src/app/api/agenda/ai-plan/route.ts` + `slimmeTakenTemplates` tabel met system templates). Templates zijn generiek (`{placeholder}` substitutie), de Haiku kent geen klant/project context.

**Oplossing:**
- Bridge krijgt een tweede output: naast `blokken[]` ook `slimme_acties[]` array in plan-JSON
- Elke slimme actie: `{ titel, beschrijving, cluster, duurMin, voor: sem|syb|team, prioriteit, bronTaakId? }`
- `commit-planning.sh` schrijft deze naar een nieuwe tabel `slimme_acties_bridge` (apart van `slimmeTakenTemplates` zodat de oude weg onaangeroerd blijft)
- Rechter panel (Slimme Acties) leest primary uit `slimme_acties_bridge` (filtert op `voor=currentUser OR voor=team`), met `slimmeTakenTemplates` als fallback als panel leeg is
- Nieuwe tabel:
  ```sql
  CREATE TABLE slimme_acties_bridge (
    id INTEGER PRIMARY KEY,
    titel TEXT NOT NULL,
    beschrijving TEXT,
    cluster TEXT,
    duurMin INTEGER,
    voor TEXT NOT NULL,  -- sem|syb|team
    prioriteit TEXT,
    bronTaakId INTEGER REFERENCES taken(id),
    gecreeerdOp TEXT NOT NULL,
    verlooptOp TEXT NOT NULL  -- auto-cleanup na 48u
  );
  ```
- Cleanup-cron: dagelijks 04:00 UTC verwijdert expired rows

**UI:** Slimme Acties panel krijgt filter-tabs: `Voor mij` / `Team` / `Alles`. Klik op een actie → modal met "Plan in agenda" (timeslot picker, default vandaag eerste vrije slot).

### Phase 4 — Haiku-planner naar fallback

**Probleem:** zowel bridge als Haiku genereren nu blokken — werk duplicatie, en Haiku-output is mindere kwaliteit.

**Oplossing:**
- `/api/agenda/ai-plan` blijft bestaan maar krijgt guard: check of er voor dezelfde datum al bridge-blokken zijn (`eigenaar in (sem, syb, team) AND gemaaktDoor='bridge'`). Zo ja → error 409 "Er is al een bridge-plan voor deze dag. Verwijder handmatig om opnieuw te plannen."
- UI "AI plan" knop wordt "Fallback plan" knop, alleen zichtbaar als `agenda_voor_datum.length === 0`
- `gemaaktDoor` kolom op agenda: `'user' | 'bridge' | 'fallback-haiku' | 'ai-plan-button'`
- Bestaande `slimmeTakenTemplates` tabel blijft voor de fallback — dus geen code-deletie, alleen demotie

**Migration:**
```sql
ALTER TABLE agenda ADD COLUMN IF NOT EXISTS gemaaktDoor TEXT NOT NULL DEFAULT 'user';
```

### Phase 5 — Klant-project dimensie + GTM-ritme slots

**Probleem:** blokken in agenda hebben geen klant-context. Bij 3+ actieve klanten + GTM-werk + intern werk = moeilijk in één oogopslag te zien *wat voor dag* het is ("LP Brands dag?" "Sales Engine dag?" "content batching?").

**Oplossing A — klant-label op elk blok:**
- `agenda` tabel krijgt `projectId INTEGER REFERENCES projecten(id) NULL` kolom
- Bridge plant blokken mét projectId als de taak aan een project gekoppeld is (via `taken.projectId`)
- UI rendert project-naam bovenin blok + accent-rand-kleur uit een stabiele hash van projectId (zodat LP Brands altijd dezelfde cyan rand krijgt, Nukeware altijd paars, etc.)
- Legenda rechtsboven agenda: klikbaar filter ("alleen LP Brands tonen") → dimt andere blokken

**Oplossing B — Project Focus Mode:**
- Op project-detail-pagina nieuwe knop "Plan een focus-dag" → kies datum + uren (6u default)
- Backend: marker op agenda rij = `focusProject: projectId, focusDag: datum`
- Bridge ziet die marker bij volgende run → plant zoveel mogelijk blokken voor dat project op die dag (max uren), de rest van de dag gaat naar GTM-ritme of andere projecten

**Oplossing C — GTM-ritme slots:**
- `gtm_ritme_slots` tabel: `{ gebruiker, pijler, startTijd, eindTijd, dagenVanWeek, actief }`
- Defaults geladen bij bridge-init:
  - `{ sem, "sales_engine", "09:00", "10:30", [ma,di,wo,do,vr] }` — 10 scans + outreach
  - `{ sem, "content", "Zaterdag 10:00", "11:00" }` — weekend batch
  - `{ syb, "lead_intake", "09:00", "10:00", [ma,do] }` — ICP filter
  - `{ sem+syb, "engagement", "16:30", "17:00", [ma,di,wo,do,vr] }` — LinkedIn reply/comment
- Bridge respecteert deze slots als "protected" tijd — plant er GTM-slimme-acties in (scan batch, content-review, engagement), niet klant-werk
- UI: deze slots krijgen een zachte achtergrond-tint per pijler (Sales Engine = teal glow, content = warm oranje) — visueel herkenbaar zelfs vóór de bridge ze gevuld heeft

**Schema:**
```sql
ALTER TABLE agenda ADD COLUMN IF NOT EXISTS projectId INTEGER REFERENCES projecten(id);
ALTER TABLE agenda ADD COLUMN IF NOT EXISTS focusProject INTEGER REFERENCES projecten(id);
ALTER TABLE slimme_acties_bridge ADD COLUMN IF NOT EXISTS pijler TEXT;
-- pijler enum: 'sales_engine' | 'content' | 'inbound' | 'netwerk' | 'delivery' | 'intern' | 'admin'

CREATE TABLE IF NOT EXISTS gtm_ritme_slots (
  id INTEGER PRIMARY KEY,
  gebruiker TEXT NOT NULL, -- sem | syb | team
  pijler TEXT NOT NULL,
  label TEXT NOT NULL,  -- "Sales Engine batch"
  startTijd TEXT NOT NULL, -- "09:00"
  eindTijd TEXT NOT NULL,
  dagenVanWeek TEXT NOT NULL, -- JSON: ["ma","di","wo","do","vr"]
  actief INTEGER NOT NULL DEFAULT 1,
  gecreeerdOp TEXT NOT NULL
);
```

### Phase 6 — On-demand Atlas↔Autro overleg (cross-chat)

**Probleem:** de v1 bridge is puur nachtelijk. Maar overdag verandert alles: een nieuwe klant belt om 11:00, een deal wordt gesloten om 14:00, een bestaande klant escaleert om 15:30. Sem kan in zijn chat zeggen "overleg met Autro hoe we dit morgen verdelen" en Atlas moet dat real-time kunnen.

**Oplossing — leverage het bestaande `chat-requests/inbox-<tag>/` systeem:**

De cross-chat infrastructuur bestaat al (Skill(chats) → send/inbox/active). Bridge v2 voegt een **overleg-intent** bovenop:
- Sem zegt tegen Atlas: "overleg met Autro hoe we morgen LP Brands oppakken"
- Atlas post in chat-requests naar Autro's actieve chat-tag (via `Skill(chats) active` → zoek Syb's recentste tag)
- Autro's chat (bij Syb) krijgt `inbox` notificatie, pikt 't op volgende prompt, antwoordt met voorstel
- Atlas leest Autro's reactie, stelt verdeling voor aan Sem
- Bij akkoord → Atlas schrijft DIRECT naar `/api/agenda` met nieuwe verdeling (zonder op 20:30 te wachten)

**Nieuwe endpoint:**
- `POST /api/agenda/herschikking` — accepteert `{ datum, verplaatsBlokken: [{id, nieuweStart, nieuweEigenaar?}], nieuweBlokken: [...] }`
- Transactional: of alles lukt of niets
- Authoriseert op API-key (user = Atlas/Autro), respecteert existing bridge-dedup

**UI:** kleine "laatste overleg" balk onder de agenda: "14:23 — Atlas → Autro: LP Brands morgen vol voor Sem (9-17); Nukeware verschoven naar donderdag. ✓ toegepast."

**Geen heen-en-weer loops:** max 2 rondes overleg per dag per klant (voorkom eindeloze chat-request pingpong). Daarna eskaleert naar Discord `#claude-handoffs` voor mens-tot-mens.

## Data flow end-to-end

**Nachtelijk (gepland):**
```
20:30 (Atlas) → fetch-context (taken + projecten + GTM-slots + actieve klanten)
              → Claude → { blokken[], slimme_acties[], focus_project_voorstel? }
              → POST /api/agenda (eigenaar=sem, projectId, gemaaktDoor=bridge)
              → POST /api/slimme-acties-bridge (voor=sem|team, pijler)
              → Discord #dagplanning (PLANNING-SEM, leesbaar incl. klant-namen)

20:45 (Autro) → fetch-context (ziet Atlas' blokken + team-taken)
              → Claude (partner_voorstel = Atlas' post)
              → POST /api/agenda + slimme-acties (eigenaar=syb|team)
              → Discord #dagplanning (PLANNING-SYB, ack op team-taken)

08:00         → beiden open dashboard
              → eigen lane + team-blokken overspannend + klant-accent-kleuren
              → slimme acties gefilterd op "Voor mij / Team / Alles"
              → GTM-ritme slots zichtbaar als zachte pijler-tint
```

**Overdag (on-demand, Phase 6):**
```
11:30 Sem  → "Atlas, overleg met Autro of hij woensdag LP Brands kan oppakken"
Atlas      → lookup Autro's actieve chat-tag via Skill(chats) active
           → post chat-request naar Syb's inbox
(Syb's chat) → Autro pikt request op, antwoordt vanuit eigen context
Atlas      → bevestigt verdeling met Sem
           → POST /api/agenda/herschikking (transactional)
           → UI updates live (optimistic + server-verify)
           → Discord #dagplanning: "HERSCHIKKING 11:47 — LP Brands wo → Sem; Nukeware do → Syb"
```

## Niet-functionele eisen

- **Migrations idempotent** — `ADD COLUMN IF NOT EXISTS`
- **Backwards compat** — oude agenda-rows zonder eigenaar renderen in 'vrij' lane
- **Re-run semantics** — bridge mag per (datum, eigenaar) opnieuw runnen; tweede run verwijdert eerst bestaande `gemaaktDoor='bridge'` rows voor die combinatie en schrijft dan opnieuw (dedup in commit-planning.sh). Nooit dubbele blokken.
- **`verlooptOp` slimme actie** — bridge zet = `start_of_tomorrow + 48h`. Cron cleanup verwijdert rows waar `verlooptOp < now()`.
- **Stilte-detectie** — als beide bridges 3 dagen niets posten → automatische Discord alert naar `#alerts`

## Design beslissingen & tradeoffs

| Beslissing | Alternatief | Waarom dit |
|---|---|---|
| Swim lanes per persoon | Kleur-per-persoon in gedeelde kolom | Lanes zijn robuust bij veel items; kleur faalt bij colorblind + stapelproblemen |
| Aparte `slimme_acties_bridge` tabel | Hergebruik `slimmeTakenTemplates` met nieuwe `voor` kolom | Gescheiden tabellen laten fallback-pad intact; makkelijk rollback |
| `team` eigenaar spant beide lanes | Derde "team" kolom | Meeting-achtige blokken horen inhoudelijk tussen beide, niet naast |
| Haiku als fallback, niet delete | Delete + alleen bridge | Mac-asleep scenario heeft alsnog een plan nodig |
| Discord blijft transparantielaag | Dashboard als enige state | Jullie lezen sneller Discord op telefoon dan dashboard open |
| Klant-kleur via stabiele hash van projectId | Handmatig per project een kleur kiezen | Hash = zero-config, altijd consistent, schaalt mee met nieuwe klanten |
| GTM-ritme als aparte tabel | Hardcoded in prompt | Tabel = flexibel, per-user bewerkbaar, renderbaar als background tint |
| Chat-requests inbox voor on-demand overleg | Nieuwe Turso-tabel `overleg_log` | Infrastructuur bestaat al, meta-systeem hergebruiken |
| Max 2 overleg-rondes, dan Discord | Onbeperkt heen-weer | Voorkomt oneindige AI-loops, dwingt mens-beslissing bij vaagheid |
| `projectId` nullable op agenda | Verplicht project | Niet alle blokken zijn klant-werk (lunch, engagement) |

## Risico's

1. **Bridge fails silent** — als `/api/agenda` POST 500 geeft voor één blok, wordt het geskipt maar de rest gaat door. Verhelpt via Discord-alert bij `fail_count > 0`.
2. **Eigenaar mismatch** — als bridge een blok schrijft met `eigenaar=sem` maar Sem is die dag niet beschikbaar (ziek), blijft 't staan. Manueel verwijderen. Accept — geen auto-detectie in v2.
3. **Migration op live Turso** — beide `ALTER TABLE` commando's moeten op prod. Run in laag-verkeer venster (zondag), test eerst op staging-branch DB.
4. **UI redesign regression** — bestaande drag-and-drop kan breken bij lane switch. Mitigatie: feature flag `agenda_lanes_v2` in `feature_flags` tabel (als bestaand) of env var; rollback = toggle uit.

## Open vragen

- **Lane volgorde** — Sem links, Syb rechts, of per-user toggle? (Syb ziet zichzelf liever links in zijn eigen dashboard?)
- **Vrij-lane** — eigen smalle 3e kolom rechts, of ghost-overlay op de andere lanes? Voorstel: eigen smalle kolom zodat "pak op"-items visueel apart staan.
- **Migration volgorde** — eerst schema + fallback-guard, dan UI, dan bridge-updates. Klopt dat voor jullie build-volgorde?
- **Klant-accent kleurpalet** — een handvol predefined kleuren (cyan, paars, oranje, roze, groen) die cyclisch worden toegewezen, of vrije hue-hash? Risico: hue-hash kan "saaie" bruin/beige produceren. Voorstel: palette van 10 vaste hoog-contrast kleuren.
- **GTM-ritme defaults** — zijn de voorgestelde slots (Sales Engine 09:00–10:30 werkdagen, content zaterdag 10–11, engagement 16:30 werkdagen, Syb ICP-filter ma+do 09–10) correct? Of wil je andere ritme?
- **Project-focus-mode scope** — mag de bridge zelf voorstellen een focus-dag te maken ("morgen is LP Brands achter op schema, ik stel voor woensdag focus-dag Sem")? Of alleen reageren op handmatig ingestelde focus?
- **On-demand overleg trigger** — moet Atlas ook proactief Autro pingen (bv bij escalatie van klant), of alleen op expliciet verzoek van Sem? Conservatief voorstel: alleen op verzoek in v2.

## Next

Na approval van dit design: invoke `writing-plans` skill voor gedetailleerde task-by-task implementatie plan. Aangezien dit 6 phases raakt, splits de plans per phase in:
- `2026-04-NN-bridge-v2-phase1-agenda-ui-swim-lanes.md`
- `2026-04-NN-bridge-v2-phase2-eigenaar-kolom-bridge-write.md`
- `2026-04-NN-bridge-v2-phase3-slimme-acties-bridge.md`
- `2026-04-NN-bridge-v2-phase4-haiku-fallback.md`
- `2026-04-NN-bridge-v2-phase5-klant-project-gtm-ritme.md`
- `2026-04-NN-bridge-v2-phase6-on-demand-overleg.md`

Phases 1-4 zijn MVP (basis van v2 agenda werkt). Phase 5-6 zijn wat het écht nuttig maakt voor klant-werk (LP Brands ritme, real-time overleg). Valideer na phase 4 of phases 5-6 nog steeds het juiste is of opnieuw denken.
