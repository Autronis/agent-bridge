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

## Scope

**In:**
- UI redesign agenda-view: twee lanes Sem/Syb, clean blokken, betere visuele hierarchie
- Agenda API + DB: `eigenaar` veld op agenda-items (bestaat op taken, nieuw op agenda) + lane rendering
- Bridge schrijft niet alleen blokken maar óók Slimme Acties naar dashboard
- Haiku-planner `/api/agenda/ai-plan` → fallback mode (alleen gebruikt als bridge niet draaide)
- Bridge post Discord-overleg-bericht blijft bestaan (transparantie), maar **dashboard is primary state**

**Uit:**
- Realtime overleg tussen Atlas en Autro (blijft async, één ronde zoals v1)
- Google Calendar sync (staat al, blijft zoals 't is)
- Turso coordinatie-tabel (Discord posts blijven state machine)
- Mobiele agenda-redesign (alleen desktop in deze iteratie)

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
 tijd  │ Sem                  │ Syb                  │ vrij
 ─────┼──────────────────────┼──────────────────────┼──────
 09:00 │ [Demo voorbereiden]  │ [Supabase schema]    │
       │ [claude·demo]        │                      │
 10:00 │                      │ [Cold outreach #1]   │ [onboard fietsenzaak]
       │                      │ [handmatig]          │
 11:00 │ ═══════ Team: Intake klant X ═══════════    │
 12:30 │ ─── lunch ──────────────────────────────────│
```

**UitlegBlock** bovenaan pagina (per CLAUDE.md feedback memory): korte tekst over lanes + hoe slepen werkt.

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

## Data flow end-to-end

```
20:30 (Atlas Mac)      → fetch-context → Claude → { blokken[], slimme_acties[] }
                        → POST /api/agenda (eigenaar=sem, gemaaktDoor=bridge)
                        → POST /api/slimme-acties-bridge (voor=sem|team)
                        → Discord post (PLANNING-SEM, leesbaar)

20:45 (Autro Mac)      → fetch-context (ziet Atlas' blokken!) → Claude (met partner_voorstel)
                        → POST /api/agenda (eigenaar=syb|team, gemaaktDoor=bridge)
                        → POST /api/slimme-acties-bridge (voor=syb|team)
                        → Discord post (PLANNING-SYB, met ack van Atlas' team-taken)

08:00 morgen           → beide users openen dashboard
                        → zien eigen lane + team-lane + slimme acties filtered op eigen naam
                        → slepen/pakken taken naar agenda wanneer nodig
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

## Risico's

1. **Bridge fails silent** — als `/api/agenda` POST 500 geeft voor één blok, wordt het geskipt maar de rest gaat door. Verhelpt via Discord-alert bij `fail_count > 0`.
2. **Eigenaar mismatch** — als bridge een blok schrijft met `eigenaar=sem` maar Sem is die dag niet beschikbaar (ziek), blijft 't staan. Manueel verwijderen. Accept — geen auto-detectie in v2.
3. **Migration op live Turso** — beide `ALTER TABLE` commando's moeten op prod. Run in laag-verkeer venster (zondag), test eerst op staging-branch DB.
4. **UI redesign regression** — bestaande drag-and-drop kan breken bij lane switch. Mitigatie: feature flag `agenda_lanes_v2` in `feature_flags` tabel (als bestaand) of env var; rollback = toggle uit.

## Open vragen

- **Syb's visuele voorkeur** — moet `syb` lane links staan of rechts? (Sem links default, maar Syb kan eigen toggle hebben in settings)
- **Wat bij `eigenaar=vrij`** — krijgt dit een eigen lane (smaller, rechts) of rendert 't als ghost-item bovenop Sem lane? Voorstel: eigen smalle lane zodat "pak op" visueel onderscheidt van eigen werk.
- **Migration volgorde** — eerst schema + fallback-guard, dan UI (want UI is afhankelijk van `eigenaar` kolom). Klopt dat voor jullie build-volgorde?

## Next

Na approval van dit design: invoke `writing-plans` skill voor gedetailleerde task-by-task implementatie plan dat per phase een aparte `docs/superpowers/plans/2026-04-NN-bridge-v2-phaseN-*.md` file produceert.
