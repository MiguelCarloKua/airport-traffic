extensions [table]

breed [planes plane]
breed [towers tower]
breed [trucks truck]         ;; still available if you later want fuel TRUCKs
breed [customers customer]
breed [clouds cloud]
breed [raindrops raindrop]
breed [fuelers fueler]       ;; simple fueling agent that occupies fueling lane

globals [
  runway-patches taxiway-patches gate-patches intersection-patches hangar-patches
  boarding-patches fueling-patches navigable-patches terminal-patches

  total-flights-handled total-arrivals total-departures flights-this-hour
  total-waiting-time max-delay cancelled-flights runway-utilization-time gate-occupancy-time

  flight-schedule next-arrival-time next-departure-time congestion-map
  weather-speed-multiplier base-arrival-interval base-departure-interval

  c-boarding c-fueling c-ready c-taxiing c-waiting c-emergency c-departing c-departed c-flying c-landed c-parked c-to-runway
]

planes-own [
  plane-type current-state destination flight-path current-path-index
  base-speed current-speed priority fuel-level gate-assigned waiting-time
  total-delay service-time flight-id scheduled-arrival scheduled-departure
  passengers needs-fuel needs-baggage emergency-status
  wait-counter last-patch
  boarded? fueled?
]

towers-own [ controlled-planes runway-queue gate-assignments ]
trucks-own [ truck-type assigned-plane home-base service-time busy ]
customers-own [ destination-gate ]
fuelers-own   [ assigned-gate service-remaining ]
clouds-own    [ drift ]
raindrops-own [ vy ]

patches-own [ gate? gate-reserved-by gate-occupied-by lock-ticks boarding-lane? fueling-lane? ]

; =========================
; SETUP
; =========================

to setup
  clear-all
  reset-ticks
  set weather-condition "clear"
  set season season       ;; from chooser
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
  set base-arrival-interval 20
  set base-departure-interval 25

  setup-colors
  setup-airport-layout
  setup-agents-mixed
  setup-passengers-by-season
  schedule-initial-flights
  set-weather-effects
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
  set c-boarding   rgb 255 170 220   ;; soft pink for boarding
  set c-fueling    rgb 255 160  60   ;; amber for fueling
end


; =========================
; LAYOUT
; =========================

to setup-airport-layout
  ; time-of-day palette (light → dark blue)
  let morning   (list 200 225 255)
  let midday    (list 160 195 245)
  let evening   (list 110 150 215)
  let night     (list 30  45  90)
  let base-col ifelse-value time-of-day = "morning" [morning]
               [ifelse-value time-of-day = "midday"  [midday]
               [ifelse-value time-of-day = "evening" [evening] [night]]]
  ask patches [ set pcolor rgb item 0 base-col item 1 base-col item 2 base-col ]

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

  set gate-patches patches with [
    (pycor = 60 and (pxcor = 15 or pxcor = 25 or pxcor = 35)) or
    (pycor = 60 and (pxcor = 65 or pxcor = 75 or pxcor = 85))
  ]

  ; reset flags
  ask patches [
    set gate? false
    set gate-reserved-by nobody
    set gate-occupied-by nobody
    set lock-ticks 0
    set boarding-lane? false
    set fueling-lane? false
  ]

  ; mark gates
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

  ; terminal block (top center)
  set terminal-patches patches with [ pxcor >= 40 and pxcor <= 60 and pycor >= 65 and pycor <= 75 ]
  ask terminal-patches [ set pcolor black ]

  ; create distinct lanes near each gate: one for passengers, one for fueling
  set boarding-patches no-patches
  set fueling-patches no-patches
  foreach sort gate-patches [
    g ->
    let gx [pxcor] of g
    let gy [pycor] of g
    let b patch gx (gy - 1)   ;; boarding lane (immediately below gate)
    let f patch gx (gy - 2)   ;; fueling lane below boarding
    ask b [ set pcolor violet set boarding-lane? true ]
    ask f [ set pcolor 45 set fueling-lane? true ]  ;; olive
    set boarding-patches (patch-set boarding-patches b)
    set fueling-patches  (patch-set fueling-patches  f)
  ]

  set navigable-patches (patch-set runway-patches taxiway-patches gate-patches intersection-patches)

  ask patches with [
    pxcor = min-pxcor or pxcor = max-pxcor or pycor = min-pycor or pycor = max-pycor
  ] [ set pcolor red - 2 ]
end

; =========================
; INITIAL AGENTS
; =========================

; Use slider `set-planes` to distribute initial states:
; 25% flying, 25% waiting at gates, 25% taxiing toward runway, 25% ready in hangar
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

  let n max list 0 set-planes
  let n-flying   round (n * 0.34)
  let n-waiting  round (n * 0.33)
  let n-taxiing  n - n-flying - n-waiting

  ;; flying (arrivals, above world)
  repeat n-flying [
    create-planes 1 [
      setxy random-xcor (max-pycor + 5)
      set shape "airplane" set size 1.5
      set plane-type "arriving" set current-state "flying"
      set base-speed 0.5 set current-speed base-speed
      set gate-assigned one-of gate-patches
      set destination gate-assigned
      set last-patch patch-here
      set passengers 0
      set boarded? false
      set fueled?  false
      color-by-state
    ]
  ]

  ;; waiting (already docked at a gate; needs boarding + fueling)
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
        set boarded? false
        set fueled?  false
        color-by-state
      ]
    ]
  ]

  ;; taxiing on taxiway toward runway (already full + fueled)
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
      set boarded? true
      set fueled?  true
      color-by-state
    ]
  ]
end

; spawn customers based on season
to setup-passengers-by-season
  let n ifelse-value season = "peak" [300] [100]
  create-customers n [
    move-to one-of terminal-patches
    set color white set size 0.8
    set destination-gate one-of boarding-patches
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

; animate weather overlays each tick
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
  set-weather-effects
  step-weather

  if ticks >= next-arrival-time   [ schedule-new-arrival ]
  if ticks >= next-departure-time [ schedule-new-departure ]

  manage-traffic
  ask patches with [lock-ticks > 0] [ set lock-ticks lock-ticks - 1 ]

  ; passengers head toward boarding lanes; when at a lane with a waiting plane for that gate, mark boarded
  ask customers [
    if destination-gate = nobody [ set destination-gate one-of boarding-patches ]
    face destination-gate
    if distance destination-gate > 0.5 [ fd 0.4 ]
    if distance destination-gate <= 0.5 [
      let gate-patch patch [pxcor] of destination-gate ([pycor] of destination-gate + 1)
      let plane-here one-of planes-on gate-patch
      if plane-here != nobody and [current-state] of plane-here = "waiting" [
        if [passengers] of plane-here < 50 [
          ask plane-here [
            set passengers passengers + 1
            if passengers >= 50 [ set boarded? true ]
          ]
          die
        ]
      ]
    ]
  ]


  ; fueling: if a waiting plane not fueled, spawn/maintain a fueler on fueling lane for a few ticks
  ask planes with [current-state = "waiting" and not fueled?] [
    if not any? fuelers with [assigned-gate = [gate-assigned] of myself] [
      hatch-fuelers 1 [
        set assigned-gate [gate-assigned] of myself
        move-to patch [pxcor] of assigned-gate ([pycor] of assigned-gate - 2)
        set color 45 set size 1.2 set service-remaining 12
        set shape "square"
      ]
    ]
  ]
  ask fuelers [
    set service-remaining service-remaining - 1
    if service-remaining <= 0 [
      let p one-of planes with [gate-assigned = [assigned-gate] of myself]
      if p != nobody [ ask p [ set fueled? true ] ]
      die
    ]
  ]

  ; planes state machine
  ask planes [
    if current-state = "flying" [
      let target closest-runway
      ifelse distance target < 1 [
        if patch-clear? target [ move-to target set current-state "landed" ]
      ] [
        face target fd 0.5
      ]
    ]

    if current-state = "landed" [ set current-state "taxiing" ]

    if current-state = "taxiing" [
      ifelse member? patch-here gate-patches [
        if patch-here = gate-assigned [
          ask patch-here [ set gate-occupied-by [self] of myself set gate-reserved-by nobody ]
          set current-state "waiting"
          set wait-counter 10
          set boarded? false set fueled? false
        ]
      ] [
        taxi-to-gate
      ]
    ]

    if current-state = "waiting" [
      if boarded? and fueled? [
        set last-patch nobody
        set current-state "departing"
        free-my-gate
      ]
    ]

    if current-state = "departing" [
      ifelse member? patch-here runway-patches [ set current-state "departed" set color gray ]
      [ taxi-to-runway ]
    ]

    if current-state = "departed" [
      fd-safe 1
      if xcor <= min-pxcor or xcor >= max-pxcor or ycor <= min-pycor or ycor >= max-pycor [ respawn-plane ]
    ]

    if current-state = "ready" [
      ifelse member? patch-here gate-patches [
        if patch-here = gate-assigned [ set current-state "to-runway" ]
      ] [ taxi-to-gate ]
    ]

    if current-state = "to-runway" [
      ifelse member? patch-here runway-patches [ set current-state "departed" set color gray ]
      [ taxi-to-runway ]
    ]

    color-by-state
  ]

  tick
end

; =========================
; TRAFFIC / MOVEMENT HELPERS
; =========================

to manage-traffic
  let unassigned-arrivals planes with [ plane-type = "arriving" and gate-assigned = nobody and current-state != "flying" ]
  ask unassigned-arrivals [
    let g one-of gate-patches with [ gate-reserved-by = nobody and gate-occupied-by = nobody ]
    if g != nobody [ set gate-assigned g set destination g ask g [ set gate-reserved-by myself ] ]
  ]

  let unassigned-departures planes with [ plane-type = "departing" and current-state = "ready" and gate-assigned = nobody ]
  ask unassigned-departures [
    let g one-of gate-patches with [ gate-reserved-by = nobody and gate-occupied-by = nobody ]
    if g != nobody [ set gate-assigned g set destination g ask g [ set gate-reserved-by myself ] ]
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
  let options neighbors4 with [ member? self navigable-patches and lock-ticks = 0 and not any? turtles-here ]
  let cand options
  if last-patch != nobody [
    set cand cand with [ self != [last-patch] of myself ]
    if not any? cand [ set cand options ]
  ]
  if any? cand [
    let tgt gate-assigned
    if tgt != nobody [
      let myhd heading
      let next-patch min-one-of cand [
        (distance tgt) + 0.001 * abs subtract-headings myhd ((towards myself + 180) mod 360)
      ]
      ifelse [gate?] of next-patch [
        ifelse (next-patch = tgt) and
               ([gate-occupied-by] of next-patch = nobody) and
               ([gate-reserved-by] of next-patch = self)
        [
          let prev patch-here
          face next-patch
          move-to next-patch
          set last-patch prev
          ask patch-here [ set lock-ticks 2 ]
        ] [
          let cand2 cand with [ not [gate?] of self ]
          if any? cand2 [
            let alt min-one-of cand2 [
              (distance tgt) + 0.001 * abs subtract-headings myhd ((towards myself + 180) mod 360)
            ]
            let prev patch-here
            face alt
            move-to alt
            set last-patch prev
            ask patch-here [ set lock-ticks 2 ]
          ]
        ]
      ] [
        let prev patch-here
        face next-patch
        move-to next-patch
        set last-patch prev
        ask patch-here [ set lock-ticks 2 ]
      ]
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
  setxy random-xcor (max-pycor + 5)
  set last-patch patch-here
  set current-state "flying"
  set color blue
  set shape "airplane"
  set plane-type "arriving"
  set base-speed 0.5
  set wait-counter 0
  set gate-assigned one-of gate-patches
  set destination gate-assigned
  set boarded? false set fueled? false
  color-by-state
end


to fd-safe [d]
  let p patch-ahead d
  if patch-clear? p [ fd d ]
end

to schedule-new-arrival
  let g (reserve-free-gate 60)
  if g != nobody [
    create-planes 1 [
      setxy random-xcor (max-pycor + 5)
      set last-patch patch-here
      set color white
      set shape "airplane"
      set size 1.5
      set plane-type "arriving"
      set current-state "flying"
      set base-speed 0.5
      set current-speed base-speed
      set flight-id word "ARR_" (random 10000)
      set destination g
      set gate-assigned g
      set passengers 0
      set boarded? false
      set fueled?  false
      ask g [ set gate-reserved-by myself ]
      color-by-state
    ]
    ; spawn passengers for this arrival depending on season
    let pax-count ifelse-value season = "peak" [random 80 + 120] [random 30 + 50]
    create-customers pax-count [
      move-to one-of terminal-patches
      set color white
      set size 0.8
      set destination-gate patch [pxcor] of g ([pycor] of g - 1)  ; boarding lane for that gate
    ]
    set total-arrivals total-arrivals + 1
    set total-flights-handled total-flights-handled + 1
    set flights-this-hour flights-this-hour + 1
  ]
  set next-arrival-time ticks + calculate-arrival-interval
end

to schedule-new-departure
  let g (reserve-free-gate 60)
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
      set current-speed base-speed
      set flight-id word "DEP_" (random 10000)
      set destination g
      set gate-assigned g
      set passengers 0
      set boarded? false
      set fueled?  false
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
@#$#@#$#@
GRAPHICS-WINDOW
640
22
1613
757
-1
-1
9.5545
1
6
1
1
1
0
1
1
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
337
47
507
99
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
339
122
511
172
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
345
209
403
254
Flying
count planes with [current-state = \"flying\"]
17
1
11

MONITOR
347
289
405
334
Landed
count planes with [current-state = \"taxiing\"]
17
1
11

MONITOR
345
374
403
419
Waiting
count planes with [current-state = \"waiting\"]
17
1
11

MONITOR
355
450
423
495
Departing
count planes with [current-state = \"departing\"]
17
1
11

MONITOR
362
530
427
575
Departed
count planes with [current-state = \"departed\"]
17
1
11

SLIDER
352
629
525
662
set-planes
set-planes
0
100
8.0
1
1
NIL
HORIZONTAL

CHOOSER
162
60
300
105
time-of-day
time-of-day
"morning" "midday" "evening" "midnight"
0

CHOOSER
167
127
305
172
weather-condition
weather-condition
"fog" "clear" "rain" "snow"
1

CHOOSER
70
230
208
275
season
season
"peak" "off-peak"
1

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
