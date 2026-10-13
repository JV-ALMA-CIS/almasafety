/**
 * The standard inspection templates, installed per organization by
 * `installDefaultInspectionTemplates` and editable afterwards.
 *
 * The daily inspection and weekly walk-down are GENERAL — for any site and
 * any kind of work. Work-specific checks live in their own templates (e.g.
 * "Roof work inspection") that a Site Manager limits to the sites doing
 * that work (`siteIds` on the template).
 *
 * Content is taken from the JV ALMA C.I.S. Safety Plan (Accident Prevention
 * Plan, rev 1-25) for the Rosslyn Ridge roof replacement: Section 7 (daily
 * inspections by the Safety Manager, SSHO and Foremen), Section 6a (safety
 * checklist), Section 9 (medical support, PPE) and the Appendix IX
 * requirements for every plan marked "YES" — fall protection, scaffolds,
 * electrical, machinery, demolition/removals, loading, fire prevention,
 * site sanitation and temporary facilities.
 *
 * Each item names the hazard category its deficiency is filed under when
 * marked "Not OK" (see `inspection_callable.ts`'s `submitInspection`).
 */

export type InspectionKind = "daily" | "weekly" | "environmental" |
  "welfare" | "other";

export interface TemplateItem {
  id: string;
  text: string;
  hazardCategory: string;
}

export interface TemplateSection {
  title: string;
  items: TemplateItem[];
}

export interface DefaultTemplate {
  defaultKey: string;
  name: string;
  kind: InspectionKind;
  description: string;
  sections: TemplateSection[];

  /**
   * Installed by "Install standard checklists" (the general daily
   * inspection and weekly walk-down). The others are in the checklist
   * library, added one at a time where that work is done.
   */
  core: boolean;
}

/**
 * Builds a section, numbering its items `<prefix>1`, `<prefix>2`, …
 *
 * @param {string} prefix the item id prefix.
 * @param {string} title the section title.
 * @param {Array<[string, string]>} items [text, hazardCategory] pairs.
 * @return {TemplateSection} the section.
 */
function section(
  prefix: string,
  title: string,
  items: Array<[string, string]>
): TemplateSection {
  return {
    title,
    items: items.map(([text, hazardCategory], index) => ({
      id: `${prefix}${index + 1}`,
      text,
      hazardCategory,
    })),
  };
}

export const DEFAULT_TEMPLATES: DefaultTemplate[] = [
  {
    defaultKey: "daily-site-inspection",
    name: "Daily site inspection",
    kind: "daily",
    core: true,
    description:
      "Quick daily check by the Foreman / SSHO (Safety Plan, Section 7).",
    sections: [
      section("d", "Daily checks", [
        ["Everyone wears the required PPE: hard hat, safety glasses, work " +
          "gloves, safety boots, reflective vest", "ppe"],
        ["Fall protection in place for any work 6 ft (1.8 m) or higher — " +
          "guardrail, or harness tied off to an anchorage", "workingAtHeight"],
        ["Edges, openings and stairwells guarded or covered",
          "workingAtHeight"],
        ["Area below overhead work barricaded and signed (falling objects)",
          "workingAtHeight"],
        ["Scaffolds level, fully planked, guardrails fitted, accessed by " +
          "ladder (not cross-braces)", "workingAtHeight"],
        ["Electrical cords undamaged; GFCI on temporary power", "electrical"],
        ["Hand and power tools have guards in place; faulty tools tagged " +
          "out of service", "equipment"],
        ["Housekeeping: walkways clear, debris removed, materials stacked",
          "housekeeping"],
        ["Fire extinguisher and first-aid kit in place", "fire"],
        ["Drinking water and toilets available", "other"],
      ]),
    ],
  },
  {
    defaultKey: "weekly-hse-walkdown",
    name: "Weekly HSE walk-down",
    kind: "weekly",
    core: true,
    description:
      "Full weekly walk-down by the SSHO and Safety Manager (Safety Plan, " +
      "Sections 6, 7, 9 and Appendix IX).",
    sections: [
      section("a", "A. Documents & emergency readiness", [
        ["Accident Prevention Plan and Activity Hazard Analyses on site and " +
          "current", "other"],
        ["Emergency numbers and the site's clinic / medical provider " +
          "details posted", "other"],
        ["First-aid kit stocked (latex gloves, CPR shield); trained " +
          "first-aider on shift", "other"],
        ["Fire extinguishers charged, inspected and accessible", "fire"],
        ["Emergency / evacuation plan for fires and spills known to the crew",
          "fire"],
        ["Accident notification and reporting procedure known", "other"],
      ]),
      section("b", "B. Personal protective equipment", [
        ["Required PPE issued and worn by every worker", "ppe"],
        ["PPE in serviceable condition; damaged items marked out of service " +
          "and removed", "ppe"],
        ["Full-body harnesses and lanyards inspected before use", "ppe"],
      ]),
      section("c", "C. Fall protection & work at height", [
        ["Guardrails with top rail, mid rail and toe board where a fall of " +
          "6 ft or more is possible", "workingAtHeight"],
        ["Harness anchorages independent of platforms (5,000 lb per worker); " +
          "lifelines not tied to guardrails", "workingAtHeight"],
        ["Two lanyards used for vertical movement", "workingAtHeight"],
        ["Floor holes covered or guarded", "workingAtHeight"],
        ["Ladders in good condition, secured, extending 3 ft above the " +
          "landing", "workingAtHeight"],
      ]),
      section("e", "D. Scaffolds & elevating work platforms", [
        ["Scaffolds level and plumb, on base plates and mudsills; wheels " +
          "locked on rolling scaffolds", "workingAtHeight"],
        ["Platforms fully planked (gaps of 1\" or less), at least 18\" wide",
          "workingAtHeight"],
        ["Guardrails on open sides and ends; tied in when taller than 4× the " +
          "base width", "workingAtHeight"],
        ["Safe clearance from overhead power lines", "electrical"],
      ]),
      section("f", "E. Electrical", [
        ["Electrical work only by qualified personnel", "electrical"],
        ["Flexible cords inspected, undamaged, not hung from nails or " +
          "stapled", "electrical"],
        ["Outdoor and wet-location enclosures weatherproof", "electrical"],
        ["Circuits and portable tools grounded (or double-insulated)",
          "electrical"],
        ["Temporary lights guarded, not hung by their cords; GFCI on all " +
          "temporary outlets", "electrical"],
      ]),
      section("g", "F. Machinery & vehicles", [
        ["Machinery inspected and certified safe by a competent person",
          "equipment"],
        ["Fire extinguisher (5-B:C) on board loaders, cranes and similar " +
          "equipment", "fire"],
        ["Reverse alarm working on self-propelled equipment", "equipment"],
        ["Belts, gears, shafts and other moving parts guarded", "equipment"],
        ["Crane at least 10 ft from power lines; swing radius barricaded; " +
          "no one under loads", "equipment"],
      ]),
      section("h", "G. Removals & loading", [
        ["Utilities and service lines isolated before removals", "electrical"],
        ["Debris openings guarded (42\" guardrail or barricade) and signed",
          "workingAtHeight"],
        ["Loading / unloading controlled; materials kept in the set-down " +
          "areas", "housekeeping"],
      ]),
      section("i", "H. Fire prevention & housekeeping", [
        ["Waste and combustible materials removed regularly", "housekeeping"],
        ["Ignition sources and fuels controlled", "fire"],
        ["Welding / cutting: fire precautions and screening in place", "fire"],
      ]),
      section("j", "I. Sanitation & welfare", [
        ["Drinking water available, dispenser with a tap and marked " +
          "\"Drinking Water\"", "other"],
        ["Toilets provided and clean", "other"],
        ["Washing facilities with running water and soap (or sanitizer)",
          "other"],
        ["Waste bins covered and emptied daily", "housekeeping"],
        ["No food or drink in toilets or areas exposed to toxic materials",
          "other"],
      ]),
      section("k", "J. Temporary facilities & public protection", [
        ["Site office and storage anchored and electrically grounded",
          "other"],
        ["Fencing and construction warning signs where residents or the " +
          "public pass", "other"],
        ["Temporary areas drained; free of debris and rubbish",
          "housekeeping"],
      ]),
      section("l", "K. Follow-up", [
        ["Deficiencies from the last walk-down are corrected", "other"],
      ]),
    ],
  },
  {
    defaultKey: "roof-work-inspection",
    name: "Roof work inspection",
    kind: "daily",
    core: false,
    description:
      "Daily add-on for sites doing roofing (e.g. Rosslyn Ridge) — limit it " +
      "to those sites under \"Used at\".",
    sections: [
      section("r", "Roof work", [
        ["Roof work protected: guardrails, warning line 6 ft from the edge, " +
          "or a safety monitor", "workingAtHeight"],
        ["Roofers' harnesses tied off to anchorages rated 5,000 lb",
          "workingAtHeight"],
        ["Fragile areas and openings in the roof covered or guarded",
          "workingAtHeight"],
        ["Area below the roof edge barricaded and signed", "workingAtHeight"],
        ["Materials on the roof spread out, secured and away from the edges",
          "housekeeping"],
        ["Debris lowered by rope, hoist or chute — never thrown",
          "housekeeping"],
        ["Roof work stopped in strong wind or rain", "workingAtHeight"],
      ]),
    ],
  },
  // ---- The library: added one at a time from "Checklist library" and
  // ---- limited to the sites doing that work. General requirements from
  // ---- the Safety Plan's Appendix IX (EM 385-1-1), not site-specific.
  {
    defaultKey: "scaffolds-ladders",
    name: "Scaffolds & ladders",
    kind: "daily",
    core: false,
    description:
      "Before each shift wherever scaffolds or ladders are in use.",
    sections: [
      section("sc", "Scaffolds", [
        ["Inspected by a competent person before the shift and tagged",
          "workingAtHeight"],
        ["Level and plumb on base plates and mudsills; rolling scaffold " +
          "wheels locked", "workingAtHeight"],
        ["Tied to the structure when taller than 4× its base width",
          "workingAtHeight"],
        ["Platforms fully planked, gaps 1\" or less, at least 18\" wide",
          "workingAtHeight"],
        ["Guardrails (top rail, mid rail, toe board) on open sides and ends",
          "workingAtHeight"],
        ["Access by ladder, stair tower or ramp — never by the cross-braces",
          "workingAtHeight"],
        ["Safe clearance from overhead power lines", "electrical"],
      ]),
      section("ld", "Ladders", [
        ["Ladders in good condition: no broken rungs, rails or feet",
          "equipment"],
        ["On firm, level ground, tied off, extending 3 ft above the landing",
          "workingAtHeight"],
        ["Three points of contact kept; loads not carried up by hand",
          "workingAtHeight"],
      ]),
    ],
  },
  {
    defaultKey: "electrical-temporary-power",
    name: "Electrical & temporary power",
    kind: "weekly",
    core: false,
    description: "Weekly check of temporary power, cords and electrical work.",
    sections: [
      section("el", "Electrical", [
        ["Electrical work done only by qualified persons", "electrical"],
        ["GFCI on every temporary power outlet, tested", "electrical"],
        ["Cords inspected daily by users: undamaged, grounded, no improper " +
          "splices", "electrical"],
        ["Cords protected from vehicles, feet and sharp edges; not stapled " +
          "or hung from nails", "electrical"],
        ["Circuits and portable tools grounded or double-insulated",
          "electrical"],
        ["Panels and breakers in closed, weatherproof enclosures; live parts " +
          "guarded", "electrical"],
        ["Temporary lights guarded, not hung by their cords; empty sockets " +
          "filled", "electrical"],
        ["Lockout/tagout used before work on circuits or equipment",
          "electrical"],
        ["Clearance surveyed before work near overhead power lines",
          "electrical"],
      ]),
    ],
  },
  {
    defaultKey: "excavations",
    name: "Excavations & trenches",
    kind: "daily",
    core: false,
    description:
      "Daily, and after rain, wherever there is digging or trenching.",
    sections: [
      section("ex", "Excavations", [
        ["Inspected by a competent person today (and after rain)", "other"],
        ["Underground services located and marked before digging",
          "electrical"],
        ["Shoring, benching or sloping for depths over 5 ft (1.5 m) or " +
          "unstable soil", "other"],
        ["No work where water is collecting until it is controlled", "other"],
        ["Spoil and materials kept at least 2 ft back from the edge",
          "housekeeping"],
        ["Ladder, ramp or stairs for depths over 4 ft, within 25 ft of " +
          "every worker", "workingAtHeight"],
        ["Edges barricaded and signed; the public kept out",
          "workingAtHeight"],
        ["No digging below nearby structures unless supported or approved " +
          "by an engineer", "other"],
      ]),
    ],
  },
  {
    defaultKey: "machinery-cranes",
    name: "Machinery & cranes",
    kind: "daily",
    core: false,
    description: "Before use, for mechanised equipment and lifting.",
    sections: [
      section("mc", "Machinery", [
        ["Inspected and certified safe by a competent person", "equipment"],
        ["Operated only by trained, authorised operators", "equipment"],
        ["Reverse alarm working on self-propelled equipment", "equipment"],
        ["Fire extinguisher (5-B:C) on board", "fire"],
        ["Belts, gears, shafts and other moving parts guarded", "equipment"],
      ]),
      section("cr", "Cranes & lifting", [
        ["Crane level, outriggers fully extended on firm blocking",
          "equipment"],
        ["At least 10 ft from power lines; rear swing radius barricaded",
          "equipment"],
        ["Load chart, manual and logbook in the cab", "equipment"],
        ["Rigging inspected; tag lines used; nobody under or riding a load",
          "equipment"],
      ]),
    ],
  },
  {
    defaultKey: "fire-hot-work",
    name: "Fire prevention & hot work",
    kind: "other",
    core: false,
    description:
      "Wherever there is welding, cutting, grinding or fuel on site.",
    sections: [
      section("fi", "Fire prevention & hot work", [
        ["Fire extinguishers charged, inspected and within reach", "fire"],
        ["Hot work: combustibles cleared or covered, fire watch in place",
          "fire"],
        ["Fuels and flammables labelled and stored away from ignition " +
          "sources", "chemical"],
        ["Gas cylinders upright, secured and capped when not in use", "fire"],
        ["Waste and combustible materials removed regularly", "housekeeping"],
        ["Escape routes and the assembly point known and clear", "fire"],
        ["Smoking only in designated areas", "fire"],
      ]),
    ],
  },
  {
    defaultKey: "demolition",
    name: "Demolition & removals",
    kind: "daily",
    core: false,
    description: "Daily wherever structures are being taken down or removed.",
    sections: [
      section("dm", "Demolition & removals", [
        ["Surveys done before work (structure, asbestos, lead)", "chemical"],
        ["Services shut off, capped or otherwise controlled", "electrical"],
        ["Hazardous materials removed or controlled before work begins",
          "chemical"],
        ["Debris chutes and openings guarded (42\" guardrail); drop areas " +
          "barricaded and signed", "workingAtHeight"],
        ["Walls over 6 ft braced unless they stand safely on their own",
          "other"],
        ["Nobody below while material is removed", "workingAtHeight"],
        ["Floors checked strong enough before machinery is used on them",
          "equipment"],
        ["Glass and sharp debris controlled", "housekeeping"],
      ]),
    ],
  },
  {
    defaultKey: "welfare-sanitation",
    name: "Site welfare & sanitation",
    kind: "welfare",
    core: false,
    description: "Weekly check of drinking water, toilets and first aid.",
    sections: [
      section("wf", "Welfare", [
        ["Drinking water available (cool in hot weather), dispenser with a " +
          "tap, marked", "other"],
        ["Toilets provided and clean", "other"],
        ["Washing facilities with running water and soap (or sanitizer)",
          "other"],
        ["No food or drink in toilets or areas with toxic materials",
          "other"],
        ["Covered waste bins, emptied daily", "housekeeping"],
        ["Shaded rest area available", "other"],
        ["First-aid kit stocked; a first-aider on every shift", "other"],
        ["Emergency numbers and the clinic's details posted", "other"],
      ]),
    ],
  },
];
