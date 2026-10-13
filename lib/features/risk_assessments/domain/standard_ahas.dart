import 'risk_assessment.dart';

/// Starting drafts for the two features of work the Safety Plan lists in
/// Section 10 ("1 Removals", "2 Roof construction") for the roof replacement
/// of the 22 type "A" townhomes (Section 2.d). Written from the plan's own
/// requirements — fall protection, scaffolds, demolition, electrical,
/// machinery, sanitation (Appendix IX). They are only a starting point: the
/// competent person who prepares the AHA must check every line against the
/// actual site before it is accepted.
const standardAhas = <AhaContent>[
  AhaContent(
    featureOfWork: 'Removals',
    activity:
        'Dismantling and temporary removal of the existing roofs of the '
        'type "A" townhomes',
    steps: [
      AhaStep(
        step: 'Set up the work area below the roof',
        hazards: [
          'Falling objects striking workers, residents or the public',
          'Unauthorised people entering the work area',
        ],
        controls: [
          'Barricade and sign the area below the roof edge before work starts',
          'Temporary fencing where the public or residents pass; construction '
              'hazard signs on the fencing',
          'Keep the barricaded area clear of people while work is overhead',
        ],
      ),
      AhaStep(
        step: 'Erect scaffold and access ladders',
        hazards: [
          'Falls from the scaffold or ladder',
          'Scaffold collapse or tipping',
          'Contact with overhead power lines',
        ],
        controls: [
          'Survey for overhead power lines first; no scaffold near lines until '
              'they are insulated, de-energised or made safe',
          'Scaffold level and plumb on base plates and mudsills; tied to the '
              'building if taller than 4 times its base width',
          'Platforms fully planked (gaps no more than 1"), guardrails on open '
              'sides and ends',
          'Access by ladder or stair tower, never by the cross-braces; ladders '
              'tied off and extending 3 ft above the landing',
          'Competent person inspects the scaffold before use',
        ],
      ),
      AhaStep(
        step: 'Isolate services on and near the roof',
        hazards: [
          'Electric shock from wiring, fittings or roof-mounted equipment',
          'Damage to water or other service lines',
        ],
        controls: [
          'Shut off, cap or otherwise control services before removal starts',
          'De-energise circuits and apply lockout/tagout; qualified electrician '
              'only; test before touching',
          'Protect any service that must stay live',
        ],
      ),
      AhaStep(
        step: 'Remove roof coverings, flashings and gutters',
        hazards: [
          'Falls from the roof edge or through openings and fragile areas',
          'Cuts from sheet edges, nails and broken material',
          'Dust; possible asbestos or lead in old roofing',
          'Back injuries from handling heavy material',
        ],
        controls: [
          'Fall protection for all work 6 ft or higher: guardrails, a full-body '
              'harness tied off to an anchorage rated 5,000 lb, a warning line '
              '6 ft from the edge, or a safety monitor',
          'Confirm the roofing has been checked for asbestos and lead before '
              'removal; stop work and report if suspected',
          'Walk only on supported structure; cover or guard openings',
          'Cut-resistant gloves, safety glasses, dust masks',
          'Team lifts for heavy pieces; do not overload one area of the roof',
        ],
      ),
      AhaStep(
        step: 'Dismantle battens and roof structure being replaced',
        hazards: [
          'Partial collapse of the remaining structure',
          'Struck by falling timber or tools',
          'Puncture wounds from nails',
          'Injury from power tools',
        ],
        controls: [
          'Dismantle in a planned sequence; brace what remains',
          'Nobody below while members are removed',
          'Remove or bend over protruding nails straight away',
          'Tools with guards in place, cords inspected daily, GFCI on all '
              'temporary power',
          'Hard hats for everyone in the area',
        ],
      ),
      AhaStep(
        step: 'Lower and clear debris',
        hazards: [
          'Debris falling or being thrown from the roof',
          'Trips over waste; fire in waste piles',
          'Manual handling injuries',
        ],
        controls: [
          'Lower material by rope, hoist or enclosed chute — never throw it',
          'Chute openings guarded at 42"; drop areas barricaded at least 6 ft '
              'back and signed',
          'Clear and stack debris daily; covered waste bins emptied daily',
          'Fire extinguisher at the work area; no burning of waste',
        ],
      ),
      AhaStep(
        step: 'Weather-protect the open roof at the end of each day',
        hazards: [
          'Wind lifting covers or loose sheets',
          'Slippery surfaces in rain',
          'Heat stress and sun exposure',
        ],
        controls: [
          'Secure temporary covers; tie down or remove loose material',
          'Stop roof work in strong wind or rain',
          'Drinking water, shade and rest breaks in hot weather',
        ],
      ),
    ],
    equipment: [
      'Scaffolding and ladders',
      'Full-body harnesses, lanyards (two for vertical movement), lifelines '
          'and roof anchors',
      'Warning line or guardrail system',
      'Pry bars, hammers and hand tools',
      'Power tools: grinder, reciprocating saw, drill (with GFCI-protected '
          'cords)',
      'Rope and pulley, hoist or debris chute',
      'Wheelbarrows and skips / waste bins',
      'Barricade tape, fencing and warning signs',
      'Fire extinguisher and first-aid kit',
      'PPE: hard hat, safety glasses, gloves, safety boots, reflective vest, '
          'dust masks',
    ],
    inspectionRequirements: [
      'Scaffold inspected by a competent person before each shift and after '
          'bad weather',
      'Harnesses, lanyards and anchorages checked before each use',
      'Electrical cords, tools and GFCIs inspected daily by the user',
      'Barricades and signs checked daily',
      'Daily site inspection and weekly HSE walk-down',
    ],
    trainingRequirements: [
      'This AHA explained to the whole crew before work begins (daily safety '
          'meeting)',
      'Fall protection training for everyone working at height',
      'Scaffold users trained; scaffold erected by competent persons',
      'Ladder safety and manual handling',
      'Hazard communication: dust, asbestos and lead awareness',
      'First aid (a first-aider on every shift) and fire extinguisher use',
    ],
  ),
  AhaContent(
    featureOfWork: 'Roof construction',
    activity: 'New roofs for the type "A" townhomes',
    steps: [
      AhaStep(
        step: 'Receive materials and lift them to the roof',
        hazards: [
          'Struck by a load being lifted',
          'Back injuries from manual handling',
          'Materials sliding or falling from the roof',
          'Overloading the roof structure',
        ],
        controls: [
          'Plan each lift; tag lines on loads; nobody under a load',
          'If a crane is used: competent operator and rigger, 10 ft from power '
              'lines, swing radius barricaded, load chart in the cab',
          'Spread and secure materials on the roof, away from the edges',
          'Team lifts; mechanical lifting where possible',
        ],
      ),
      AhaStep(
        step: 'Install trusses and roof structure',
        hazards: [
          'Falls from height and through open framing',
          'Collapse of trusses before they are braced',
          'Struck by falling tools or timber',
        ],
        controls: [
          'Temporary bracing as the manufacturer specifies before letting go',
          'Work from the scaffold platform at the eaves; full-body harness tied '
              'off to an anchorage rated 5,000 lb when above 6 ft',
          'Two lanyards when moving vertically',
          'Hard hats; tool lanyards; area below barricaded',
        ],
      ),
      AhaStep(
        step: 'Fix battens or purlins and underlay',
        hazards: [
          'Falls from the roof',
          'Slipping on underlay, especially when wet',
          'Injury from nail guns and power tools',
        ],
        controls: [
          'Fall protection: harness tied off, warning line 6 ft from the edge, '
              'or a safety monitor',
          'Non-slip safety boots; no work on wet underlay',
          'Nail guns used only by trained workers, sequential trigger, never '
              'pointed at anyone',
          'Cords inspected daily, GFCI on temporary power',
        ],
      ),
      AhaStep(
        step: 'Lay roof covering, ridges and flashings',
        hazards: [
          'Falls from the roof edge',
          'Wind catching sheets',
          'Cuts from sheet edges',
          'Heat stress and sun exposure',
        ],
        controls: [
          'Fall protection kept in place for the whole job',
          'Do not handle sheets in strong wind; secure stacks',
          'Cut-resistant gloves',
          'Drinking water, shade, rest breaks; long sleeves and sun protection',
        ],
      ),
      AhaStep(
        step: 'Cutting, grinding and drilling',
        hazards: [
          'Flying particles',
          'Noise and dust',
          'Electric shock',
          'Fire from sparks',
        ],
        controls: [
          'Safety glasses or face shield; hearing protection; dust mask',
          'Guards fitted on grinders and saws',
          'Cords and plugs in good condition, GFCI protection',
          'Fire extinguisher within reach; keep combustibles clear',
        ],
      ),
      AhaStep(
        step: 'Fit gutters, fascias and edge details',
        hazards: [
          'Falls from the edge or from ladders',
          'Falling objects onto people below',
        ],
        controls: [
          'Work from the scaffold with guardrails',
          'Ladders on firm ground, tied off, 3 ft above the landing, '
              'three points of contact',
          'Area below barricaded and signed',
        ],
      ),
      AhaStep(
        step: 'Clean up and hand over',
        hazards: [
          'Offcuts and debris falling from the roof',
          'Trips over waste',
        ],
        controls: [
          'Clear the roof every day; lower waste by rope or chute',
          'Keep walkways and access routes clear',
          'Remove barricades only after the roof is complete and checked',
        ],
      ),
    ],
    equipment: [
      'Scaffolding and ladders',
      'Full-body harnesses, lanyards, lifelines and roof anchors',
      'Warning line or guardrail system',
      'Hoist or crane (if used), slings and tag lines',
      'Nail guns, circular saw, grinder, drills (GFCI-protected cords)',
      'Hand tools',
      'Fire extinguisher and first-aid kit',
      'PPE: hard hat, safety glasses, gloves, safety boots, reflective vest, '
          'hearing protection',
    ],
    inspectionRequirements: [
      'Scaffold inspected by a competent person before each shift and after '
          'bad weather',
      'Harnesses, lanyards and anchorages checked before each use',
      'Crane or hoist inspected and certified by a competent person before '
          'use',
      'Nail guns, power tools, cords and GFCIs inspected daily by the user',
      'Daily site inspection and weekly HSE walk-down',
    ],
    trainingRequirements: [
      'This AHA explained to the whole crew before work begins (daily safety '
          'meeting)',
      'Fall protection training for everyone working at height',
      'Nail gun and power tool training',
      'Rigging and signalling (if a crane or hoist is used)',
      'Manual handling; working in heat',
      'First aid (a first-aider on every shift) and fire extinguisher use',
    ],
  ),
];
