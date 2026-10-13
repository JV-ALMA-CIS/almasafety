/**
 * The standard inspection templates, installed per organization by
 * `installDefaultInspectionTemplates` and editable afterwards.
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
    description:
      "Quick daily check by the Foreman / SSHO (Safety Plan, Section 7).",
    sections: [
      section("d", "Daily checks", [
        ["Everyone wears the required PPE: hard hat, safety glasses, work " +
          "gloves, safety boots, reflective vest", "ppe"],
        ["Fall protection in place for any work 6 ft (1.8 m) or higher — " +
          "guardrail, or harness tied off to an anchorage", "workingAtHeight"],
        ["Roof work protected: guardrails, warning line 6 ft from the edge, " +
          "or a safety monitor", "workingAtHeight"],
        ["Area below roof work barricaded and signed (falling objects)",
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
    description:
      "Full weekly walk-down by the SSHO and Safety Manager (Safety Plan, " +
      "Sections 6, 7, 9 and Appendix IX).",
    sections: [
      section("a", "A. Documents & emergency readiness", [
        ["Accident Prevention Plan and Activity Hazard Analyses on site and " +
          "current", "other"],
        ["Emergency numbers and AAR Healthcare details posted", "other"],
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
      section("c", "C. Fall protection & roof work", [
        ["Guardrails with top rail, mid rail and toe board where a fall of " +
          "6 ft or more is possible", "workingAtHeight"],
        ["Harness anchorages independent of platforms (5,000 lb per worker); " +
          "lifelines not tied to guardrails", "workingAtHeight"],
        ["Two lanyards used for vertical movement", "workingAtHeight"],
        ["Floor holes covered or guarded", "workingAtHeight"],
        ["Roofers protected by guardrail, harness, warning line or safety " +
          "monitor", "workingAtHeight"],
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
];
