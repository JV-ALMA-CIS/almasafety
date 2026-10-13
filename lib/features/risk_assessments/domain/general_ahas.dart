import 'risk_assessment.dart';

/// General AHA starting drafts for common kinds of construction work, from
/// the general requirements in the Safety Plan's Appendix IX (EM 385-1-1):
/// scaffolds, electrical, excavations, machinery and cranes, fire
/// prevention and hot work, demolition. Not tied to any site — the
/// competent person adapts each to the actual site and work before it is
/// accepted.
const generalAhas = <AhaContent>[
  AhaContent(
    featureOfWork: 'Scaffolding',
    activity: 'Erecting, using and dismantling scaffolds',
    steps: [
      AhaStep(
        step: 'Plan and prepare the scaffold area',
        hazards: [
          'Contact with overhead power lines',
          'Scaffold on soft or uneven ground',
          'People walking under the work',
        ],
        controls: [
          'Survey for overhead power lines; keep a safe clearance or have '
              'them made safe first',
          'Firm, level foundation with base plates on mudsills',
          'Barricade and sign the area below',
        ],
      ),
      AhaStep(
        step: 'Erect the scaffold',
        hazards: [
          'Falls during erection',
          'Collapse or tipping',
          'Struck by falling components',
        ],
        controls: [
          'Erected by competent persons following the manufacturer\'s '
              'instructions',
          'Level and plumb; tied to the structure when taller than 4× its '
              'base width',
          'Full-body harness tied off where guardrails are not yet fitted',
          'Hard hats; nobody below while components are raised',
        ],
      ),
      AhaStep(
        step: 'Inspect and tag before use',
        hazards: ['Use of an incomplete or unsafe scaffold'],
        controls: [
          'Competent person inspects before each shift and after bad '
              'weather, and tags it',
          'Platforms fully planked (gaps 1" or less), guardrails on open '
              'sides and ends',
        ],
      ),
      AhaStep(
        step: 'Work from the scaffold',
        hazards: [
          'Falls from the platform',
          'Overloading',
          'Tools or materials falling',
          'Climbing the frame',
        ],
        controls: [
          'Guardrails kept in place; harness where a fall of 6 ft or more is '
              'not otherwise protected',
          'Load kept within the rated capacity',
          'Toe boards; tools and materials kept away from edges',
          'Access only by ladder, stair tower or ramp — never the '
              'cross-braces',
        ],
      ),
      AhaStep(
        step: 'Dismantle the scaffold',
        hazards: ['Falls', 'Struck by falling components'],
        controls: [
          'Dismantle top-down in sequence; keep ties until the level above '
              'is removed',
          'Lower components by hand line or hoist — never throw them',
          'Area below barricaded',
        ],
      ),
    ],
    equipment: [
      'Scaffold frames, braces, planks, base plates and mudsills',
      'Guardrails and toe boards',
      'Ladders or stair towers',
      'Full-body harnesses and lanyards',
      'Hand lines or hoist',
      'Barricades and signs',
      'PPE: hard hat, gloves, safety boots, reflective vest',
    ],
    inspectionRequirements: [
      'Scaffold inspected and tagged by a competent person before each '
          'shift and after bad weather',
      'Harnesses and lanyards checked before each use',
      'Daily site inspection',
    ],
    trainingRequirements: [
      'This AHA explained to the crew before work begins',
      'Scaffold erectors competent; scaffold users trained',
      'Fall protection training',
    ],
  ),
  AhaContent(
    featureOfWork: 'Electrical work',
    activity: 'Temporary power, wiring and electrical installation',
    steps: [
      AhaStep(
        step: 'Plan the work and isolate the supply',
        hazards: ['Electric shock or burns from live parts'],
        controls: [
          'Work done only by qualified electricians',
          'Circuits de-energised before work; lockout/tagout applied',
          'Tested dead before touching',
        ],
      ),
      AhaStep(
        step: 'Run temporary power and cords',
        hazards: [
          'Shock from damaged cords',
          'Tripping over cords',
          'Water and wet locations',
        ],
        controls: [
          'GFCI on every temporary outlet',
          'Cords inspected daily by users; damaged cords removed',
          'Cords routed away from walkways and protected from vehicles and '
              'sharp edges',
          'Weatherproof enclosures in wet locations',
        ],
      ),
      AhaStep(
        step: 'Install or modify wiring and equipment',
        hazards: ['Contact with live parts', 'Arc flash', 'Falls from ladders'],
        controls: [
          'Live parts guarded; panels kept closed',
          'Insulated tools and suitable PPE',
          'Ladders secured; non-conductive ladders near live parts',
        ],
      ),
      AhaStep(
        step: 'Work near overhead power lines',
        hazards: ['Contact by people, ladders, scaffolds or machinery'],
        controls: [
          'Survey the safe clearance distance before work starts',
          'Lines de-energised, insulated or a spotter used',
        ],
      ),
      AhaStep(
        step: 'Test and re-energise',
        hazards: ['Someone still working on the circuit'],
        controls: [
          'Everyone clear before locks are removed',
          'Only the person who applied a lock removes it',
        ],
      ),
    ],
    equipment: [
      'Distribution boards and GFCIs',
      'Extension cords and temporary lighting with guards',
      'Insulated hand tools and voltage tester',
      'Lockout/tagout kit',
      'Non-conductive ladders',
      'PPE: insulated gloves, safety glasses, safety boots',
    ],
    inspectionRequirements: [
      'Cords, plugs and tools inspected daily by the user',
      'GFCIs tested',
      'Weekly electrical check',
    ],
    trainingRequirements: [
      'This AHA explained to the crew before work begins',
      'Qualified electricians with verifiable credentials',
      'Lockout/tagout training',
    ],
  ),
  AhaContent(
    featureOfWork: 'Excavation & trenching',
    activity: 'Digging foundations, trenches and service runs',
    steps: [
      AhaStep(
        step: 'Locate underground services',
        hazards: ['Striking electric cables, water or gas pipes'],
        controls: [
          'Drawings checked and services located and marked before digging',
          'Hand-dig near marked services',
        ],
      ),
      AhaStep(
        step: 'Dig the excavation',
        hazards: [
          'Collapse of the sides',
          'Struck by the excavator',
          'Undermining nearby structures',
        ],
        controls: [
          'Shoring, benching or sloping for depths over 5 ft (1.5 m) or '
              'unstable soil',
          'Nobody within the machine\'s swing radius; banksman used',
          'No digging below nearby structures without an engineer\'s '
              'approval',
        ],
      ),
      AhaStep(
        step: 'Work in the excavation',
        hazards: [
          'Collapse',
          'Water collecting',
          'Falling material',
          'No way out',
        ],
        controls: [
          'Competent person inspects daily and after rain',
          'No work while water is collecting until it is controlled',
          'Spoil and materials kept at least 2 ft from the edge',
          'Ladder or ramp for depths over 4 ft, within 25 ft of every worker',
        ],
      ),
      AhaStep(
        step: 'Protect the edges and backfill',
        hazards: ['People or vehicles falling in'],
        controls: [
          'Edges barricaded and signed; the public kept out',
          'Backfill in layers; nobody in the trench while backfilling',
        ],
      ),
    ],
    equipment: [
      'Excavator with reverse alarm',
      'Shoring or trench boxes',
      'Ladders',
      'Barricades and signs',
      'Service locator',
      'Pump for water',
      'PPE: hard hat, safety boots, reflective vest',
    ],
    inspectionRequirements: [
      'Excavation inspected by a competent person daily and after rain',
      'Excavator inspected before use',
    ],
    trainingRequirements: [
      'This AHA explained to the crew before work begins',
      'Competent person for excavations',
      'Trained, authorised machine operators',
    ],
  ),
  AhaContent(
    featureOfWork: 'Lifting & machinery',
    activity: 'Cranes, hoists and mechanised equipment',
    steps: [
      AhaStep(
        step: 'Plan the lift',
        hazards: ['Overloading', 'Unstable ground', 'Overhead power lines'],
        controls: [
          'Load weight and radius checked against the load chart',
          'Firm ground; outriggers fully extended on blocking',
          'Crane at least 10 ft from power lines',
        ],
      ),
      AhaStep(
        step: 'Set up and inspect the equipment',
        hazards: ['Equipment failure'],
        controls: [
          'Inspected and certified safe by a competent person before use',
          'Reverse alarm, guards and fire extinguisher in place',
        ],
      ),
      AhaStep(
        step: 'Rig and lift the load',
        hazards: [
          'Dropped load',
          'Struck by the swinging load',
          'Crushed by the crane\'s rear swing',
        ],
        controls: [
          'Rigging inspected; qualified rigger and signaller',
          'Tag lines on loads; nobody under or riding a load',
          'Rear swing radius barricaded',
        ],
      ),
      AhaStep(
        step: 'Operate mobile machinery',
        hazards: ['Struck by reversing machinery', 'Rollover'],
        controls: [
          'Trained, authorised operators only',
          'Banksman for reversing; pedestrians kept apart',
          'Seat belts worn',
        ],
      ),
    ],
    equipment: [
      'Crane or hoist with load chart, manual and logbook',
      'Slings, shackles and tag lines',
      'Outrigger blocking',
      'Barricades',
      'Radios or hand signals',
      'PPE: hard hat, gloves, safety boots, reflective vest',
    ],
    inspectionRequirements: [
      'Machinery inspected and certified by a competent person before use',
      'Rigging inspected before each lift',
      'Daily pre-use checks by the operator',
    ],
    trainingRequirements: [
      'This AHA explained to the crew before work begins',
      'Certified operators, riggers and signallers',
    ],
  ),
  AhaContent(
    featureOfWork: 'Hot work',
    activity: 'Welding, cutting and grinding',
    steps: [
      AhaStep(
        step: 'Prepare the work area',
        hazards: ['Fire from sparks', 'Flammable materials nearby'],
        controls: [
          'Combustibles removed or covered with fire blankets',
          'Fire extinguisher at the work area',
          'Hot work precautions agreed with the supervisor',
        ],
      ),
      AhaStep(
        step: 'Set up the equipment',
        hazards: ['Gas leaks', 'Electric shock from welding sets'],
        controls: [
          'Cylinders upright, secured and fitted with flashback arrestors',
          'Hoses and leads inspected; welding set earthed',
        ],
      ),
      AhaStep(
        step: 'Weld, cut or grind',
        hazards: [
          'Burns',
          'Eye injury from arc flash and particles',
          'Fumes',
          'Noise',
        ],
        controls: [
          'Welding helmet, face shield or safety glasses; gloves and '
              'fire-resistant clothing',
          'Screens to protect others from arc flash',
          'Ventilation for fumes',
          'Hearing protection',
        ],
      ),
      AhaStep(
        step: 'Finish and fire watch',
        hazards: ['Smouldering material starting a fire later'],
        controls: [
          'Fire watch for at least 30 minutes after the work',
          'Cylinders closed and equipment stored',
        ],
      ),
    ],
    equipment: [
      'Welding set or gas cutting set with flashback arrestors',
      'Angle grinder with guard',
      'Fire extinguisher and fire blankets',
      'Welding screens',
      'PPE: welding helmet, face shield, gloves, fire-resistant clothing, '
          'hearing protection',
    ],
    inspectionRequirements: [
      'Equipment, hoses and leads inspected before use',
      'Area checked before and after the work',
    ],
    trainingRequirements: [
      'This AHA explained to the crew before work begins',
      'Trained welders',
      'Fire extinguisher use',
    ],
  ),
  AhaContent(
    featureOfWork: 'Demolition',
    activity: 'Taking down structures or parts of buildings',
    steps: [
      AhaStep(
        step: 'Survey and plan',
        hazards: [
          'Unexpected collapse',
          'Asbestos, lead or other hazardous materials',
        ],
        controls: [
          'Engineering, asbestos and lead surveys before work starts',
          'Demolition sequence planned by a competent person',
        ],
      ),
      AhaStep(
        step: 'Isolate services',
        hazards: ['Electric shock', 'Gas or water release'],
        controls: [
          'Services shut off, capped or otherwise controlled outside the '
              'building line',
        ],
      ),
      AhaStep(
        step: 'Remove hazardous materials',
        hazards: ['Exposure to asbestos, lead or chemicals'],
        controls: [
          'Removed or controlled by trained people before demolition begins',
          'Suitable respiratory protection',
        ],
      ),
      AhaStep(
        step: 'Demolish the structure',
        hazards: [
          'Collapse',
          'Falling debris',
          'Falls through openings',
          'Dust and noise',
        ],
        controls: [
          'Walls over 6 ft braced unless they stand safely on their own',
          'Nobody below; area barricaded and signed',
          'Openings guarded (42" guardrail)',
          'Water spray for dust; hearing protection',
        ],
      ),
      AhaStep(
        step: 'Clear debris',
        hazards: ['Cuts from glass and sharp edges', 'Manual handling'],
        controls: [
          'Debris lowered by chute or hoist; drop areas barricaded',
          'Cut-resistant gloves; team lifts',
        ],
      ),
    ],
    equipment: [
      'Hand and power tools; demolition machinery where planned',
      'Debris chute or hoist',
      'Bracing',
      'Barricades and signs',
      'Water spray',
      'PPE: hard hat, safety glasses, gloves, safety boots, dust masks, '
          'hearing protection',
    ],
    inspectionRequirements: [
      'Structure checked by a competent person daily during demolition',
      'Barricades checked daily',
      'Daily site inspection',
    ],
    trainingRequirements: [
      'This AHA explained to the crew before work begins',
      'Hazardous materials awareness (asbestos, lead)',
      'Fall protection where working at height',
    ],
  ),
];
