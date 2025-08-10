extensions [table]

breed [planes plane]
breed [towers tower]
breed [trucks truck]
breed [customers customer]
breed [clouds cloud]
breed [raindrops raindrop]
breed [fuelers fueler]

globals [
  runway-patches taxiway-patches gate-patches intersection-patches hangar-patches
  boarding-patches fueling-patches navigable-patches terminal-patches

  total-flights-handled total-arrivals total-departures flights-this-hour
  total-waiting-time max-delay cancelled-flights runway-utilization-time gate-occupancy-time

  flight-schedule next-arrival-time next-departure-time congestion-map
  weather-speed-multiplier base-arrival-interval base-departure-interval

  arrival-gate-patches
  hangar-capacity hangar-slots terminal-capacity

  c-boarding c-fueling c-ready c-taxiing c-waiting c-emergency c-departing c-departed c-flying c-landed c-parked c-to-runway
]

planes-own [
  plane-type current-state destination flight-path current-path-index
  base-speed current-speed priority fuel-level gate-assigned waiting-time
  total-delay service-time flight-id scheduled-arrival scheduled-departure
  passengers needs-fuel needs-baggage emergency-status
  wait-counter last-patch
  boarded? fueled?
  phase
  deplaning-remaining
  fueling-remaining
  pushback-remaining
  holding-angle ; for turn progress
]

towers-own [ controlled-planes runway-queue gate-assignments ]
trucks-own [ truck-type assigned-plane home-base service-time busy ]
customers-own [ destination-gate purpose]
fuelers-own   [ assigned-gate service-remaining ]
clouds-own    [ drift ]
raindrops-own [ vy ]

patches-own [ gate? gate-reserved-by gate-occupied-by lock-ticks boarding-lane? fueling-lane? fuelpad-occupied-by ]

; =========================
; SETUP
; =========================

to setup
  clear-all
  reset-ticks
  set weather-condition "clear"
  set season season
  set time-of-day time-of-day
  set total-flights-handled 0
  set total-arrivals 0
  set total-departures 0
  set flights-this-hour 0
  set total-waiting-time 0
  set max-delay 0
  set cancelled-flights 0
  set runway-utilization-time 0
  set gate-occupancy-time 0
  set flight-schedule table:make
  set congestion-map table:make
  set weather-speed-multiplier 1.0
  set base-arrival-interval arrival-interval
  set base-departure-interval departure-interval



  setup-colors
  setup-airport-layout

  set hangar-capacity 25
  set hangar-slots n-of hangar-capacity hangar-patches

  ;; terminal pool target
  set terminal-capacity 200

  setup-shapes
  setup-agents-mixed
  schedule-initial-flights
  set-weather-effects
end

to setup-shapes
  set-default-shape customers "arrow"
end

to setup-colors
  set c-ready      rgb 0 0 0
  set c-taxiing    rgb 153 0 255
  set c-waiting    rgb 255 64 129
  set c-emergency  rgb 255 0 0
  set c-departing  rgb 0 128 255
  set c-departed   rgb 96 96 96
  set c-flying     rgb 0 230 180
  set c-landed     rgb 255 255 0
  set c-parked     rgb 255 255 255
  set c-to-runway  rgb 0 200 0
  set c-boarding   rgb 255 170 220
  set c-fueling    rgb 255 160 60
end

; =========================
; LAYOUT
; =========================

to setup-airport-layout
  let morning   (list 200 225 255)
  let midday    (list 160 195 245)
  let evening   (list 110 150 215)
  let night     (list 30  45  90)
  let base-col ifelse-value time-of-day = "morning" [morning]
               [ifelse-value time-of-day = "midday"  [midday]
               [ifelse-value time-of-day = "evening" [evening] [night]]]
  ask patches [ set pcolor rgb item 0 base-col item 1 base-col item 2 base-col ]
  ask patches [ set fuelpad-occupied-by nobody ]

  set runway-patches patches with [
    (pycor = 25 and pxcor >= 20 and pxcor <= 80) or
    (pxcor = 50 and pycor >= 35 and pycor <= 55)
  ]
  ask runway-patches [ set pcolor blue + 2 ]

  set taxiway-patches patches with [
    (pycor = 30 and pxcor >= 15 and pxcor <= 85) or
    (pycor = 35 and pxcor >= 15 and pxcor <= 85) or
    (pycor = 45 and pxcor >= 15 and pxcor <= 85) or
    (pycor = 50 and pxcor >= 15 and pxcor <= 85) or
    (pxcor = 15 and pycor >= 25 and pycor <= 60) or
    (pxcor = 25 and pycor >= 25 and pycor <= 60) or
    (pxcor = 35 and pycor >= 25 and pycor <= 60) or
    (pxcor = 65 and pycor >= 25 and pycor <= 60) or
    (pxcor = 75 and pycor >= 25 and pycor <= 60) or
    (pxcor = 85 and pycor >= 25 and pycor <= 60)
  ]
  ask taxiway-patches [ set pcolor gray ]

  ;; --- connect hangar to the taxiway grid ---
  let hangar-conn patches with [
    (pycor = 45 and pxcor >= 10 and pxcor <= 15) or   ;; horizontal spur to main grid
    (pxcor = 10 and pycor >= 40 and pycor <= 50)      ;; vertical edge by hangar
  ]
  set taxiway-patches (patch-set taxiway-patches hangar-conn)
  ask hangar-conn [ set pcolor gray ]

  set gate-patches patches with [
    (pycor = 60 and (pxcor = 15 or pxcor = 25 or pxcor = 35)) or
    (pycor = 60 and (pxcor = 65 or pxcor = 75 or pxcor = 85))
  ]

  ask patches [
    set gate? false
    set gate-reserved-by nobody
    set gate-occupied-by nobody
    set lock-ticks 0
    set boarding-lane? false
    set fueling-lane? false
  ]

  ask gate-patches [
    set gate? true
    set pcolor green + 1
  ]

  set intersection-patches patches with [
    member? self taxiway-patches and count neighbors with [member? self taxiway-patches] >= 3
  ]
  ask intersection-patches [ set pcolor yellow ]

  set hangar-patches patches with [ pxcor >= 5 and pxcor <= 10 and pycor >= 40 and pycor <= 50 ]
  ask hangar-patches [ set pcolor brown ]

  set terminal-patches patches with [ pxcor >= 40 and pxcor <= 60 and pycor >= 65 and pycor <= 75 ]
  ask terminal-patches [ set pcolor black ]

  set boarding-patches no-patches
  set fueling-patches  no-patches
  foreach sort gate-patches [
    g ->
    let gx [pxcor] of g
    let gy [pycor] of g
    let b patch gx (gy - 1)
    let f patch gx (gy - 2)
    ask b [ set pcolor violet set boarding-lane? true ]
    ask f [ set pcolor 45 set fueling-lane? true ]
    set boarding-patches (patch-set boarding-patches b)
    set fueling-patches  (patch-set fueling-patches  f)
  ]

  set arrival-gate-patches gate-patches
  set navigable-patches (patch-set runway-patches taxiway-patches gate-patches intersection-patches fueling-patches hangar-patches)
end

; =========================
; INITIAL AGENTS
; =========================

to setup-agents-mixed
  create-towers 1 [
    setxy 50 30
    set color red
    set size 2
    set controlled-planes []
    set runway-queue []
    set gate-assignments table:make
    set label "ATC"
  ]

  let n set-planes ;max list 0 set-planes
  let n-flying   round (n * 0.34)
  let n-waiting  round (n * 0.33)
  let n-taxiing  n - n-flying - n-waiting

  ;; Arrivals start in the air with 50 pax to deplane; no pre-assigned gate
  repeat n-flying [
    create-planes 1 [
      setxy random-xcor (max-pycor)
      set shape "airplane" set size 1.5
      set plane-type "arriving" set current-state "flying"
      set base-speed plane-speed set current-speed base-speed
      set last-patch patch-here
      set passengers 50
      set phase "arrival"
      set boarded? false
      set fueled? false
      set gate-assigned nobody
      set destination nobody
      color-by-state
    ]
  ]

  ;; Departures waiting at gates (they will go fuel first)
  let free-gates gate-patches with [ gate-occupied-by = nobody and gate-reserved-by = nobody ]
  repeat n-waiting [
    if any? free-gates [
      let g one-of free-gates
      set free-gates other free-gates with [ self != g ]
      create-planes 1 [
        move-to g
        ask g [ set gate-occupied-by myself ]
        set shape "airplane" set size 1.5
        set plane-type "departing" set current-state "waiting"
        set base-speed 0.5 set current-speed base-speed
        set gate-assigned g set destination g
        set passengers 0
        set phase "turnaround"
        set boarded? false
        set fueled? false
        color-by-state
      ]
    ]
  ]

  ;; Some already taxiing to runway (e.g., after boarding)
  repeat n-taxiing [
    let t one-of taxiway-patches
    create-planes 1 [
      move-to t
      set last-patch patch-here
      set shape "airplane" set size 1.5
      set plane-type "departing" set current-state "to-runway"
      set base-speed 0.5 set current-speed base-speed
      set gate-assigned nobody set destination one-of runway-patches
      set passengers 50
      set phase "turnaround"
      set boarded? true
      set fueled? true
      color-by-state
    ]
  ]
end

to schedule-initial-flights
  set next-arrival-time ticks + calculate-arrival-interval
  set next-departure-time ticks + calculate-departure-interval
end

; =========================
; WEATHER EFFECTS
; =========================

to set-weather-effects
  if weather-condition = "clear" [
    set weather-speed-multiplier 1.0
    ask clouds [ die ]
    ask raindrops [ die ]
  ]
  if weather-condition = "rain" [
    set weather-speed-multiplier 0.8
    if count raindrops < 250 [
      create-raindrops 40 [
        setxy random-xcor max-pycor
        set color cyan set size 0.5
        set vy (1 + random-float 0.5)
        set shape "dot"
      ]
    ]
  ]
  if weather-condition = "fog" [
    set weather-speed-multiplier 0.6
    if count clouds < 8 [
      create-clouds 1 [
        setxy random-xcor (random (max-pycor - 5) + 3)
        set color gray + 3
        set size (10 + random 8)
        set drift (0.2 + random-float 0.2)
        set shape "circle"
      ]
    ]
  ]
  if weather-condition = "snow" [
    set weather-speed-multiplier 0.5
  ]

  ask planes [
    set current-speed max list 0.01 (base-speed * weather-speed-multiplier)
  ]
end

to step-weather
  ask raindrops [
    set ycor ycor - vy
    if ycor < min-pycor [ die ]
  ]
  ask clouds [
    set xcor xcor + drift
    if xcor > max-pxcor + 5 [ set xcor (min-pxcor - 5) set ycor random-ycor ]
  ]
end

; =========================
; MAIN LOOP
; =========================
to go
  ;; --- global updates ---
  set-weather-effects
  step-weather

  ifelse continuous-spawn? [ ; if true, just keep spawning, if false, up to set-planes
    if ticks >= next-arrival-time   [ schedule-new-arrival ]
    if ticks >= next-departure-time [ schedule-new-departure ]
  ] [
    if count planes <= set-planes [
      if ticks >= next-arrival-time   [ schedule-new-arrival ]
      if ticks >= next-departure-time [ schedule-new-departure ]
    ]
  ]


  manage-traffic

  ask patches with [ lock-ticks > 0 ] [ set lock-ticks lock-ticks - 1 ]

  ;; keep terminal stocked up to 200 boarding passengers (no more)
  ensure-terminal-stock

  ;; =========================
  ;; CUSTOMERS (PASSENGERS)
  ;; =========================
  let passenger-speed 0.45
  let active-pads (boarding-patches with [ has-boarding-plane? ])
  ask customers [
    if shape != "arrow" [ set shape "arrow" ]
    if size < 1.2 [ set size 1.2 ]
    if color = black [ ifelse purpose = "arrive" [ set color blue ] [ set color yellow ] ]

    ;; -------- destination selection / retarget every tick --------
    if purpose = "board" [
      ifelse any? active-pads [
        let nearest min-one-of active-pads [ distance myself ]
        set destination-gate nearest
      ] [
        ;; no active gates -> wait at terminal
        set destination-gate one-of terminal-patches
      ]
    ]
    if purpose = "arrive" [
      if destination-gate = nobody [ set destination-gate one-of terminal-patches ]
    ]

    ;; -------- movement --------
    if destination-gate != nobody [
      face destination-gate
      ifelse distance destination-gate > 0.5 [
        fd passenger-speed
      ] [
        ;; -------- arrival actions --------

        ;; Boarding at purple patch: board only if there is still a boarding plane
        if (purpose = "board") and [boarding-lane?] of destination-gate [
          if [has-boarding-plane?] of destination-gate [
            let gate-patch patch ([pxcor] of destination-gate) (([pycor] of destination-gate) + 1)
            let plane-here [gate-occupied-by] of gate-patch
            if (plane-here != nobody) and ([current-state] of plane-here = "boarding") and ([passengers] of plane-here < 50) [
              ask plane-here [ set passengers passengers + 1 ]
              die
            ]
          ]
          ;; if no plane anymore, next tick we’ll retarget back to terminal
        ]

        ;; Arrivals reaching terminal → despawn (they don't count in the 200 pool)
        if (purpose = "arrive") and ([pcolor] of destination-gate = black) [
          die
        ]
      ]
    ]
  ]

  ;; =========================
  ;; PLANES (STATE MACHINE)
  ;; =========================
  ask planes [

    ;; ---------- FLYING ----------
    if current-state = "flying" [
      let target closest-runway
      ifelse distance target < 1.5 [
        ifelse patch-clear? target [
          move-to target
          set current-state "landed"
        ]
        ;; else wait in holding pattern
        [
          set current-state "holding"
          set destination target
        ]
      ] [
        face target
        fd current-speed
      ]
    ]
    if current-state = "holding" [
      ; do a large slow turn
      rt 2                ; turn right 2 degrees each tick
      fd current-speed    ; move forward while turning
      set holding-angle holding-angle + 2

      ; after a full circle (360 degrees), try again
      if holding-angle >= 360 [
        set holding-angle 0
        ifelse patch-clear? destination [
          move-to destination
          set current-state "landed"
        ] [
          set current-state "holding-half"
          set holding-angle 0
        ]
      ]
    ]
    if current-state = "holding-half" [
      rt 2
      fd current-speed
      set holding-angle holding-angle + 2

      ;; After half loop
      if holding-angle >= 180 [
        set holding-angle 0
        ifelse patch-clear? destination [
          move-to destination
          set current-state "landed"
        ] [
          ;; Still blocked → back to full holding pattern
          set current-state "holding"
        ]
      ]
    ]
    ;; ---------- LANDED ----------
    if current-state = "landed" [
      set phase "arrival"
      let g min-one-of (gate-patches with [ gate-reserved-by = nobody and gate-occupied-by = nobody ]) [ distance myself ]

      ifelse g != nobody [
        set gate-assigned g
        ask g [ set gate-reserved-by myself ]
      ] [
        let slot one-of gate-patches with [ not any? turtles-here ] ;hangar-patches -> gate-patches
        ifelse slot != nobody [
          set gate-assigned slot
        ] [
          let fallback one-of gate-patches
          if fallback != nobody [
            set gate-assigned fallback
            ask fallback [ set gate-reserved-by myself ]
          ]
        ]
      ]
      set current-state "taxiing"
    ]

    ;; ---------- WAITING (departures created at a gate go fuel first) ----------
    if current-state = "waiting" [
      set phase "turnaround"
      if gate-assigned != nobody [
        set destination fuelpad-of gate-assigned
        set current-state "taxiing"
      ]
    ]

    ;; ---------- TAXIING ----------
    if current-state = "taxiing" [
      ;; reached a gate
      if [gate?] of patch-here and patch-here = gate-assigned [
        if (phase = "arrival") and (passengers > 0) [
          ask patch-here [ set gate-occupied-by myself set gate-reserved-by nobody ]
          set current-state "deplaning"
        ]
        if (phase = "turnaround") and (passengers = 0) [
          ask patch-here [ set gate-occupied-by myself set gate-reserved-by nobody ]
          set current-state "boarding"
        ]
      ]
      ;; reached hangar slot
      if member? patch-here hangar-patches and patch-here = gate-assigned [
        if any? gate-patches with [ gate-reserved-by = nobody and gate-occupied-by = nobody ] [
          let g2 one-of gate-patches with [ gate-reserved-by = nobody and gate-occupied-by = nobody ]
          set gate-assigned g2
          ask g2 [ set gate-reserved-by myself ]
        ]
      ]
      ;; reached destination (fuel pad) → only if pad free or ours
      if destination != nobody and patch-here = destination [
        if member? patch-here fueling-patches [
          if [fuelpad-occupied-by] of patch-here = nobody or [fuelpad-occupied-by] of patch-here = self [
            ask patch-here [ set fuelpad-occupied-by myself ]
            set fueling-remaining fueling-time
            set current-state "fueling"
          ]
        ]
      ]
      ;; otherwise keep moving
      if current-state = "taxiing" [ taxi-to-gate ]
    ]

    ;; ---------- DEPLANING (blue arrows to terminal) ----------
    if current-state = "deplaning" [
      let n min list passengers pax-offload-rate
      if n > 0 [
        ask patch-here [
          sprout n [
            set breed customers
            set shape "arrow"
            set size 1.2
            set color blue
            set purpose "arrive"
            set destination-gate one-of terminal-patches
          ]
        ]
        set passengers passengers - n
      ]
      if passengers <= 0 [
        ask gate-assigned [ if gate-occupied-by = myself [ set gate-occupied-by nobody ] ]
        set phase "turnaround"
        let gx [pxcor] of gate-assigned
        let gy [pycor] of gate-assigned
        set destination patch gx (gy - 2)  ;; fuel pad
        set current-state "taxiing"
      ]
    ]

    ;; ---------- FUELING ----------
    if current-state = "fueling" [
      set fueling-remaining fueling-remaining - 1
      if fueling-remaining <= 0 [
        ask patch-here [ if fuelpad-occupied-by = myself [ set fuelpad-occupied-by nobody ] ]
        set destination gate-assigned
        set current-state "taxiing"
      ]
    ]

    ;; ---------- BOARDING ----------
    if current-state = "boarding" [
      ;; don't auto-add: only yellow customers can increase passengers.
      if passengers >= 50 [
        set pushback-remaining 3
        set current-state "pushback"
      ]
    ]

    ;; ---------- PUSHBACK ----------
    if current-state = "pushback" [
      set pushback-remaining pushback-remaining - 1
      if pushback-remaining <= 0 [
        set destination nobody
        set current-state "to-runway"
      ]
    ]

    ;; ---------- TAXI-OUT ----------
    if current-state = "to-runway" [
      ifelse member? patch-here runway-patches [
        set current-state "departed"
        set color gray
      ] [
        taxi-to-runway
      ]
    ]

    ;; ---------- DEPARTED ----------
    if current-state = "departed" [
      fd-safe 1
      if xcor <= min-pxcor or xcor >= max-pxcor or ycor <= min-pycor or ycor >= max-pycor [
        ifelse continuous-spawn? [ die ] [ respawn-plane ]
      ]
    ]

    color-by-state
  ]
  update-plane-state-plot
  tick
end

; =========================
; PASSENGER SPAWN (terminal -> boarding)
; =========================

to ensure-terminal-stock
  ;; count boarding-purpose customers currently inside the terminal
  let terminal-boarders count customers with [
    purpose = "board" and [pcolor] of patch-here = black
  ]
  let deficit terminal-capacity - terminal-boarders
  if deficit > 0 [
    ;; throttle to avoid a giant burst in one tick
    let n min list deficit passenger-spawn-rate
    create-customers n [
      move-to one-of terminal-patches
      set shape "arrow"
      set size 1.2
      set color yellow
      set purpose "board"
      set destination-gate one-of terminal-patches
    ]
  ]
end


; =========================
; TRAFFIC / MOVEMENT HELPERS
; =========================

to manage-traffic
  let unassigned-arrivals planes with [ plane-type = "arriving" and gate-assigned = nobody and current-state != "flying" ]
  ask unassigned-arrivals [
    let g min-one-of (gate-patches with [ gate-reserved-by = nobody and gate-occupied-by = nobody ]) [ distance myself ]
    if g != nobody [
      set gate-assigned g
      set destination g
      ask g [ set gate-reserved-by myself ]
    ]
  ]

  let unassigned-departures planes with [ plane-type = "departing" and current-state = "ready" and gate-assigned = nobody ]
  ask unassigned-departures [
    let g one-of gate-patches with [ gate-reserved-by = nobody and gate-occupied-by = nobody ]
    if g != nobody [
      set gate-assigned g
      set destination g
      ask g [ set gate-reserved-by myself ]
    ]
  ]
end

to taxi-to-runway
  let options neighbors4 with [ member? self navigable-patches and lock-ticks = 0 and not any? turtles-here ]
  let cand options
  if last-patch != nobody [
    set cand cand with [ self != [last-patch] of myself ]
    if not any? cand [ set cand options ]
  ]
  if any? cand [
    let target-runway min-one-of runway-patches [ distance myself ]
    let myhd heading
    let next-patch min-one-of cand [
      (distance target-runway) + 0.001 * abs subtract-headings myhd ((towards myself + 180) mod 360)
    ]
    let prev patch-here
    face next-patch
    move-to next-patch
    set last-patch prev
    ask patch-here [ set lock-ticks 2 ]
  ]
end

to taxi-to-gate
  let options neighbors4 with [
  member? self navigable-patches and
  lock-ticks = 0 and
  not any? turtles-here and
  (not gate? or self = [gate-assigned] of myself)
]
  let cand options
  if last-patch != nobody [
    set cand cand with [ self != [last-patch] of myself ]
    if not any? cand [ set cand options ]
  ]
  if any? cand [
    let tgt gate-assigned
    if tgt != nobody [
      ;; Filter out wrong gates explicitly
      set cand cand with [ not gate? or self = tgt ]

      let myhd heading
      let next-patch min-one-of cand [
        (distance tgt) + 0.001 * abs subtract-headings myhd ((towards myself + 180) mod 360)
      ]
      let prev patch-here
      face next-patch
      move-to next-patch
      set last-patch prev
      ask patch-here [ set lock-ticks 2 ]
    ]
  ]
end

to free-my-gate
  if gate-assigned != nobody [
    ask gate-assigned [
      if gate-occupied-by = myself [ set gate-occupied-by nobody ]
      if gate-reserved-by = myself [ set gate-reserved-by nobody ]
    ]
  ]
end

to respawn-plane
  let edge random 4  ;; 0=top, 1=bottom, 2=left, 3=right
  if edge = 0 [ setxy random-xcor max-pycor ]               ;; top edge
  if edge = 1 [ setxy random-xcor min-pycor ]               ;; bottom edge
  if edge = 2 [ setxy min-pxcor random-ycor ]               ;; left edge
  if edge = 3 [ setxy max-pxcor random-ycor ]               ;; right edge

  set last-patch patch-here
  set current-state "flying"
  set color blue
  set shape "airplane"
  set plane-type "arriving"
  set base-speed 0.5
  set gate-assigned nobody
  set destination nobody
  set passengers 50
  set phase "arrival"
  set boarded? false
  set fueled? false
  color-by-state
end

to color-by-state
  if current-state = "ready"     [ set color c-ready ]
  if current-state = "taxiing"   [ set color c-taxiing ]
  if current-state = "emergency" [ set color c-emergency ]
  if current-state = "departing" [ set color c-departing ]
  if current-state = "departed"  [ set color c-departed ]
  if current-state = "flying" [
    if plane-type = "arriving" [ set color sky + 3 ]
    if plane-type != "arriving" [ set color c-flying ]
  ]
  if current-state = "holding" [ set color red ] ; when there is a plane on the runway, gotta wait for it to clear up so it circles
  if current-state = "holding-half" [ set color yellow ] ; when there is a plane on the runway, gotta wait for it to clear up so it circles
  if current-state = "landed"    [ set color c-landed ]
  if current-state = "to-runway" [ set color c-to-runway ]
  if current-state = "deplaning" [ set color c-waiting ]
  if current-state = "fueling"   [ set color c-fueling ]
  if current-state = "boarding"  [ set color c-boarding ]
  if current-state = "pushback"  [ set color c-ready ]
  if current-state = "waiting" [
    if not fueled? [ set color c-fueling ]
    if fueled? and passengers < 50 [ set color c-boarding ]
    if fueled? and passengers >= 50 [ set color c-waiting ]
  ]
  if current-state = "parked"    [ set color c-parked ]
end

to fd-safe [d]
  let p patch-ahead d
  if patch-clear? p [ fd d ]
end

to schedule-new-arrival
  create-planes 1 [
    setxy random-xcor (max-pycor)
    set last-patch patch-here
    set color white
    set shape "airplane"
    set size 1.5
    set plane-type "arriving"
    set current-state "flying"
    set base-speed 0.5
    set current-speed base-speed
    set flight-id word "ARR_" (random 10000)
    set passengers 50
    set phase "arrival"
    set boarded? false
    set fueled? false
    set gate-assigned nobody
    set destination nobody
    color-by-state
  ]
  set total-arrivals total-arrivals + 1
  set total-flights-handled total-flights-handled + 1
  set flights-this-hour flights-this-hour + 1
  set next-arrival-time ticks + calculate-arrival-interval
end

to schedule-new-departure
  let g reserve-free-gate 60
  if g != nobody [
    create-planes 1 [
      move-to g
      ask g [ set gate-occupied-by myself ]
      set last-patch patch-here
      set color white
      set shape "airplane"
      set size 1.5
      set plane-type "departing"
      set current-state "waiting"
      set base-speed 0.5
      set flight-id word "DEP_" (random 10000)
      set destination g
      set gate-assigned g
      set passengers 0
      set phase "turnaround"
      set boarded? false
      set fueled? false
      color-by-state
    ]
    set total-departures total-departures + 1
    set total-flights-handled total-flights-handled + 1
    set flights-this-hour flights-this-hour + 1
  ]
  set next-departure-time ticks + calculate-departure-interval
end

; =========================
; REPORTERS
; =========================

to-report customer-spawn-prob
  let p 0.08
  if season = "peak" [ set p p + 0.06 ]
  if member? time-of-day ["morning" "evening"] [ set p p + 0.04 ]
  if time-of-day = "night" [ set p p - 0.03 ]
  report max list 0 (min list 0.5 p)
end

to-report calculate-arrival-interval
  let interval base-arrival-interval
  if time-of-day = "morning" or time-of-day = "evening" [ set interval interval * 0.7 ]
  if time-of-day = "midday"  [ set interval interval * 1.0 ]
  if time-of-day = "night"   [ set interval interval * 1.5 ]
  if season = "peak"     [ set interval interval * 0.8 ]
  if season = "off-peak" [ set interval interval * 1.2 ]
  report max list 1 interval
end

to-report calculate-departure-interval
  let interval base-departure-interval
  if time-of-day = "morning" or time-of-day = "evening" [ set interval interval * 0.7 ]
  if time-of-day = "midday"  [ set interval interval * 1.0 ]
  if time-of-day = "night"   [ set interval interval * 1.5 ]
  if season = "peak"     [ set interval interval * 0.8 ]
  if season = "off-peak" [ set interval interval * 1.2 ]
  report max list 1 interval
end

to-report reserve-free-gate [ gate-y ]
  report one-of gate-patches with [ pycor = gate-y and gate-reserved-by = nobody and gate-occupied-by = nobody ]
end

to-report closest-runway
  report min-one-of runway-patches [distance myself]
end

to-report patch-clear? [p]
  report (p != nobody) and (not any? turtles-on p) and ([lock-ticks] of p = 0)
end

to-report free-arrival-gate
  report one-of arrival-gate-patches with [ gate-reserved-by = nobody and gate-occupied-by = nobody ]
end

to-report hangar-has-space?
  report (count planes with [ member? patch-here hangar-slots ]) < hangar-capacity
end

to-report pick-free-hangar-slot
  report one-of hangar-slots with [ not any? turtles-here ]
end

to-report can-land?
  report (free-arrival-gate != nobody) or hangar-has-space?
end

to-report pax-offload-rate
  let r 6
  if season = "peak" [ set r r - 2 ]
  if member? time-of-day ["morning" "evening"] [ set r r - 1 ]
  report max list 1 r
end

to-report pax-board-rate
  let r 4
  if season = "peak" [ set r r + 2 ]
  if member? time-of-day ["morning" "evening"] [ set r r + 1 ]
  report max list 1 r
end

to-report fueling-time
  report max list 5 (round (12 + random-normal 0 3))
end

to-report fuelpad-of [g]
  report patch ([pxcor] of g) (([pycor] of g) - 2)
end

to-report has-boarding-plane?   ;; PATCH context (use on a boarding patch)
  let gate-patch patch (pxcor) (pycor + 1)   ;; green gate just behind this purple patch
  if gate-patch = nobody [ report false ]
  let plane-here [gate-occupied-by] of gate-patch
  report (plane-here != nobody) and ([current-state] of plane-here = "boarding")
end

; plots

to update-plane-state-plot
  set-current-plot "Plane States"

  set-current-plot-pen "flying"
  plot count planes with [current-state = "flying"]

  set-current-plot-pen "holding"
  plot count planes with [current-state = "holding"]

  set-current-plot-pen "holding-half"
  plot count planes with [current-state = "holding-half"]

  set-current-plot-pen "landed"
  plot count planes with [current-state = "landed"]

  set-current-plot-pen "taxiing"
  plot count planes with [current-state = "taxiing"]

  set-current-plot-pen "fueling"
  plot count planes with [current-state = "fueling"]

  set-current-plot-pen "boarding"
  plot count planes with [current-state = "boarding"]

  set-current-plot-pen "pushback"
  plot count planes with [current-state = "pushback"]

  set-current-plot-pen "waiting"
  plot count planes with [current-state = "waiting"]

  set-current-plot-pen "to-runway"
  plot count planes with [current-state = "to-runway"]

  set-current-plot-pen "departed"
  plot count planes with [current-state = "departed"]

  set-current-plot-pen "deplaning"
  plot count planes with [current-state = "deplaning"]

  set-current-plot-pen "parked"
  plot count planes with [current-state = "parked"]
end
@#$#@#$#@
GRAPHICS-WINDOW
487
19
1460
754
-1
-1
9.5545
1
6
1
1
1
0
0
0
1
0
100
0
75
1
1
1
ticks
30.0

BUTTON
313
20
483
72
setup
setup
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
313
80
485
130
go
go
T
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

MONITOR
314
240
372
285
Flying
count planes with [current-state = \"flying\"]
17
1
11

MONITOR
314
189
372
234
Taxiing
count planes with [current-state = \"taxiing\"]
17
1
11

MONITOR
379
190
437
235
Waiting
count planes with [current-state = \"waiting\"]
17
1
11

MONITOR
313
340
381
385
Departing
count planes with [current-state = \"departing\"]
17
1
11

MONITOR
386
339
451
384
Departed
count planes with [current-state = \"departed\"]
17
1
11

SLIDER
5
527
178
560
set-planes
set-planes
0
100
15.0
1
1
NIL
HORIZONTAL

CHOOSER
166
20
304
65
time-of-day
time-of-day
"morning" "midday" "evening" "midnight"
0

CHOOSER
166
69
304
114
weather-condition
weather-condition
"fog" "clear" "rain" "snow"
1

CHOOSER
166
117
304
162
season
season
"peak" "off-peak"
1

MONITOR
381
290
438
335
Fueling
count planes with [current-state = \"fueling\"]
17
1
11

MONITOR
314
290
376
335
Landed
count planes with [current-state = \"landed\"]
17
1
11

MONITOR
376
137
438
182
Boarding
count planes with [current-state = \"boarding\"]
17
1
11

MONITOR
377
241
450
286
To-runway
count planes with [current-state = \"to-runway\"]
17
1
11

MONITOR
314
137
372
182
Ready
count planes with [current-state = \"ready\"]
17
1
11

MONITOR
313
390
370
435
Holding
count planes with [current-state = \"holding\"]
17
1
11

MONITOR
375
390
455
435
Holding-Half
count planes with [current-state = \"holding-half\"]
17
1
11

MONITOR
312
439
386
484
Emergency
count planes with [current-state = \"emergency\"]
17
1
11

MONITOR
389
439
459
484
Deplaining
count planes with [current-state = \"deplaining\"]
17
1
11

MONITOR
312
486
377
531
Pushback
count planes with [current-state = \"pushback\"]
17
1
11

MONITOR
382
487
439
532
Parked
count planes with [current-state = \"Parked\"]
17
1
11

PLOT
4
168
308
336
Plane States
time
count
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"flying" 1.0 0 -7500403 true "" ""
"holding" 1.0 0 -2674135 true "" ""
"holding-half" 1.0 0 -955883 true "" ""
"landed" 1.0 0 -6459832 true "" ""
"taxiing" 1.0 0 -1184463 true "" ""
"fueling" 1.0 0 -10899396 true "" ""
"boarding" 1.0 0 -13840069 true "" ""
"pushback" 1.0 0 -14835848 true "" ""
"waiting" 1.0 0 -11221820 true "" ""
"to-runway" 1.0 0 -13791810 true "" ""
"departed" 1.0 0 -13345367 true "" ""
"deplaning" 1.0 0 -8630108 true "" ""
"parked" 1.0 0 -5825686 true "" ""

SLIDER
4
346
179
379
passenger-spawn-rate
passenger-spawn-rate
0
100
40.0
1
1
NIL
HORIZONTAL

SLIDER
4
383
176
416
plane-speed
plane-speed
0.1
2
0.5
0.1
1
NIL
HORIZONTAL

SLIDER
4
420
176
453
arrival-interval
arrival-interval
5
100
20.0
1
1
NIL
HORIZONTAL

SLIDER
6
457
178
490
departure-interval
departure-interval
5
100
25.0
1
1
NIL
HORIZONTAL

SWITCH
5
564
144
597
continuous-spawn?
continuous-spawn?
0
1
-1000

@#$#@#$#@
## WHAT IS IT?

(a general understanding of what the model is trying to show or explain)

## HOW IT WORKS

(what rules the agents use to create the overall behavior of the model)

## HOW TO USE IT

(how to use the model, including a description of each of the items in the Interface tab)

## THINGS TO NOTICE

(suggested things for the user to notice while running the model)

## THINGS TO TRY

(suggested things for the user to try to do (move sliders, switches, etc.) with the model)

## EXTENDING THE MODEL

(suggested things to add or change in the Code tab to make the model more complicated, detailed, accurate, etc.)

## NETLOGO FEATURES

(interesting or unusual features of NetLogo that the model uses, particularly in the Code tab; or where workarounds were needed for missing features)

## RELATED MODELS

(models in the NetLogo Models Library and elsewhere which are of related interest)

## CREDITS AND REFERENCES

(a reference to the model's URL on the web if it has one, as well as any other necessary credits, citations, and links)
@#$#@#$#@
default
true
0
Polygon -7500403 true true 150 5 40 250 150 205 260 250

airplane
true
0
Polygon -7500403 true true 150 0 135 15 120 60 120 105 15 165 15 195 120 180 135 240 105 270 120 285 150 270 180 285 210 270 165 240 180 180 285 195 285 165 180 105 180 60 165 15

arrow
true
0
Polygon -7500403 true true 150 0 0 150 105 150 105 293 195 293 195 150 300 150

box
false
0
Polygon -7500403 true true 150 285 285 225 285 75 150 135
Polygon -7500403 true true 150 135 15 75 150 15 285 75
Polygon -7500403 true true 15 75 15 225 150 285 150 135
Line -16777216 false 150 285 150 135
Line -16777216 false 150 135 15 75
Line -16777216 false 150 135 285 75

bug
true
0
Circle -7500403 true true 96 182 108
Circle -7500403 true true 110 127 80
Circle -7500403 true true 110 75 80
Line -7500403 true 150 100 80 30
Line -7500403 true 150 100 220 30

butterfly
true
0
Polygon -7500403 true true 150 165 209 199 225 225 225 255 195 270 165 255 150 240
Polygon -7500403 true true 150 165 89 198 75 225 75 255 105 270 135 255 150 240
Polygon -7500403 true true 139 148 100 105 55 90 25 90 10 105 10 135 25 180 40 195 85 194 139 163
Polygon -7500403 true true 162 150 200 105 245 90 275 90 290 105 290 135 275 180 260 195 215 195 162 165
Polygon -16777216 true false 150 255 135 225 120 150 135 120 150 105 165 120 180 150 165 225
Circle -16777216 true false 135 90 30
Line -16777216 false 150 105 195 60
Line -16777216 false 150 105 105 60

car
false
0
Polygon -7500403 true true 300 180 279 164 261 144 240 135 226 132 213 106 203 84 185 63 159 50 135 50 75 60 0 150 0 165 0 225 300 225 300 180
Circle -16777216 true false 180 180 90
Circle -16777216 true false 30 180 90
Polygon -16777216 true false 162 80 132 78 134 135 209 135 194 105 189 96 180 89
Circle -7500403 true true 47 195 58
Circle -7500403 true true 195 195 58

circle
false
0
Circle -7500403 true true 0 0 300

circle 2
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240

cow
false
0
Polygon -7500403 true true 200 193 197 249 179 249 177 196 166 187 140 189 93 191 78 179 72 211 49 209 48 181 37 149 25 120 25 89 45 72 103 84 179 75 198 76 252 64 272 81 293 103 285 121 255 121 242 118 224 167
Polygon -7500403 true true 73 210 86 251 62 249 48 208
Polygon -7500403 true true 25 114 16 195 9 204 23 213 25 200 39 123

cylinder
false
0
Circle -7500403 true true 0 0 300

dot
false
0
Circle -7500403 true true 90 90 120

face happy
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 255 90 239 62 213 47 191 67 179 90 203 109 218 150 225 192 218 210 203 227 181 251 194 236 217 212 240

face neutral
false
0
Circle -7500403 true true 8 7 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Rectangle -16777216 true false 60 195 240 225

face sad
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 168 90 184 62 210 47 232 67 244 90 220 109 205 150 198 192 205 210 220 227 242 251 229 236 206 212 183

fish
false
0
Polygon -1 true false 44 131 21 87 15 86 0 120 15 150 0 180 13 214 20 212 45 166
Polygon -1 true false 135 195 119 235 95 218 76 210 46 204 60 165
Polygon -1 true false 75 45 83 77 71 103 86 114 166 78 135 60
Polygon -7500403 true true 30 136 151 77 226 81 280 119 292 146 292 160 287 170 270 195 195 210 151 212 30 166
Circle -16777216 true false 215 106 30

flag
false
0
Rectangle -7500403 true true 60 15 75 300
Polygon -7500403 true true 90 150 270 90 90 30
Line -7500403 true 75 135 90 135
Line -7500403 true 75 45 90 45

flower
false
0
Polygon -10899396 true false 135 120 165 165 180 210 180 240 150 300 165 300 195 240 195 195 165 135
Circle -7500403 true true 85 132 38
Circle -7500403 true true 130 147 38
Circle -7500403 true true 192 85 38
Circle -7500403 true true 85 40 38
Circle -7500403 true true 177 40 38
Circle -7500403 true true 177 132 38
Circle -7500403 true true 70 85 38
Circle -7500403 true true 130 25 38
Circle -7500403 true true 96 51 108
Circle -16777216 true false 113 68 74
Polygon -10899396 true false 189 233 219 188 249 173 279 188 234 218
Polygon -10899396 true false 180 255 150 210 105 210 75 240 135 240

house
false
0
Rectangle -7500403 true true 45 120 255 285
Rectangle -16777216 true false 120 210 180 285
Polygon -7500403 true true 15 120 150 15 285 120
Line -16777216 false 30 120 270 120

leaf
false
0
Polygon -7500403 true true 150 210 135 195 120 210 60 210 30 195 60 180 60 165 15 135 30 120 15 105 40 104 45 90 60 90 90 105 105 120 120 120 105 60 120 60 135 30 150 15 165 30 180 60 195 60 180 120 195 120 210 105 240 90 255 90 263 104 285 105 270 120 285 135 240 165 240 180 270 195 240 210 180 210 165 195
Polygon -7500403 true true 135 195 135 240 120 255 105 255 105 285 135 285 165 240 165 195

line
true
0
Line -7500403 true 150 0 150 300

line half
true
0
Line -7500403 true 150 0 150 150

pentagon
false
0
Polygon -7500403 true true 150 15 15 120 60 285 240 285 285 120

person
false
0
Circle -7500403 true true 110 5 80
Polygon -7500403 true true 105 90 120 195 90 285 105 300 135 300 150 225 165 300 195 300 210 285 180 195 195 90
Rectangle -7500403 true true 127 79 172 94
Polygon -7500403 true true 195 90 240 150 225 180 165 105
Polygon -7500403 true true 105 90 60 150 75 180 135 105

plant
false
0
Rectangle -7500403 true true 135 90 165 300
Polygon -7500403 true true 135 255 90 210 45 195 75 255 135 285
Polygon -7500403 true true 165 255 210 210 255 195 225 255 165 285
Polygon -7500403 true true 135 180 90 135 45 120 75 180 135 210
Polygon -7500403 true true 165 180 165 210 225 180 255 120 210 135
Polygon -7500403 true true 135 105 90 60 45 45 75 105 135 135
Polygon -7500403 true true 165 105 165 135 225 105 255 45 210 60
Polygon -7500403 true true 135 90 120 45 150 15 180 45 165 90

sheep
false
15
Circle -1 true true 203 65 88
Circle -1 true true 70 65 162
Circle -1 true true 150 105 120
Polygon -7500403 true false 218 120 240 165 255 165 278 120
Circle -7500403 true false 214 72 67
Rectangle -1 true true 164 223 179 298
Polygon -1 true true 45 285 30 285 30 240 15 195 45 210
Circle -1 true true 3 83 150
Rectangle -1 true true 65 221 80 296
Polygon -1 true true 195 285 210 285 210 240 240 210 195 210
Polygon -7500403 true false 276 85 285 105 302 99 294 83
Polygon -7500403 true false 219 85 210 105 193 99 201 83

square
false
0
Rectangle -7500403 true true 30 30 270 270

square 2
false
0
Rectangle -7500403 true true 30 30 270 270
Rectangle -16777216 true false 60 60 240 240

star
false
0
Polygon -7500403 true true 151 1 185 108 298 108 207 175 242 282 151 216 59 282 94 175 3 108 116 108

target
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240
Circle -7500403 true true 60 60 180
Circle -16777216 true false 90 90 120
Circle -7500403 true true 120 120 60

tree
false
0
Circle -7500403 true true 118 3 94
Rectangle -6459832 true false 120 195 180 300
Circle -7500403 true true 65 21 108
Circle -7500403 true true 116 41 127
Circle -7500403 true true 45 90 120
Circle -7500403 true true 104 74 152

triangle
false
0
Polygon -7500403 true true 150 30 15 255 285 255

triangle 2
false
0
Polygon -7500403 true true 150 30 15 255 285 255
Polygon -16777216 true false 151 99 225 223 75 224

truck
false
0
Rectangle -7500403 true true 4 45 195 187
Polygon -7500403 true true 296 193 296 150 259 134 244 104 208 104 207 194
Rectangle -1 true false 195 60 195 105
Polygon -16777216 true false 238 112 252 141 219 141 218 112
Circle -16777216 true false 234 174 42
Rectangle -7500403 true true 181 185 214 194
Circle -16777216 true false 144 174 42
Circle -16777216 true false 24 174 42
Circle -7500403 false true 24 174 42
Circle -7500403 false true 144 174 42
Circle -7500403 false true 234 174 42

turtle
true
0
Polygon -10899396 true false 215 204 240 233 246 254 228 266 215 252 193 210
Polygon -10899396 true false 195 90 225 75 245 75 260 89 269 108 261 124 240 105 225 105 210 105
Polygon -10899396 true false 105 90 75 75 55 75 40 89 31 108 39 124 60 105 75 105 90 105
Polygon -10899396 true false 132 85 134 64 107 51 108 17 150 2 192 18 192 52 169 65 172 87
Polygon -10899396 true false 85 204 60 233 54 254 72 266 85 252 107 210
Polygon -7500403 true true 119 75 179 75 209 101 224 135 220 225 175 261 128 261 81 224 74 135 88 99

wheel
false
0
Circle -7500403 true true 3 3 294
Circle -16777216 true false 30 30 240
Line -7500403 true 150 285 150 15
Line -7500403 true 15 150 285 150
Circle -7500403 true true 120 120 60
Line -7500403 true 216 40 79 269
Line -7500403 true 40 84 269 221
Line -7500403 true 40 216 269 79
Line -7500403 true 84 40 221 269

wolf
false
0
Polygon -16777216 true false 253 133 245 131 245 133
Polygon -7500403 true true 2 194 13 197 30 191 38 193 38 205 20 226 20 257 27 265 38 266 40 260 31 253 31 230 60 206 68 198 75 209 66 228 65 243 82 261 84 268 100 267 103 261 77 239 79 231 100 207 98 196 119 201 143 202 160 195 166 210 172 213 173 238 167 251 160 248 154 265 169 264 178 247 186 240 198 260 200 271 217 271 219 262 207 258 195 230 192 198 210 184 227 164 242 144 259 145 284 151 277 141 293 140 299 134 297 127 273 119 270 105
Polygon -7500403 true true -1 195 14 180 36 166 40 153 53 140 82 131 134 133 159 126 188 115 227 108 236 102 238 98 268 86 269 92 281 87 269 103 269 113

x
false
0
Polygon -7500403 true true 270 75 225 30 30 225 75 270
Polygon -7500403 true true 30 75 75 30 270 225 225 270
@#$#@#$#@
NetLogo 6.4.0
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
default
0.0
-0.2 0 0.0 1.0
0.0 1 1.0 0.0
0.2 0 0.0 1.0
link direction
true
0
Line -7500403 true 150 150 90 180
Line -7500403 true 150 150 210 180
@#$#@#$#@
0
@#$#@#$#@
