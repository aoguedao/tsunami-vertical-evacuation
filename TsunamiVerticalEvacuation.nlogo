extensions [
  csv
  gis
  matrix
  pathdir
  py
  table
]

breed [ nodes node ]
breed [ pedestrians pedestrian ]
directed-link-breed [ roads road ]

patches-own [
  flow_depth              ; Tsunami flow_depth  // or depth?
]

nodes-own[
  id                   ; Open Street Map node id
  horizontal_route
  vertical_route
  shelter?             ; True if it is a shelter
  evac_type            ; Evacuation shelter type if it is a shelter, else 0
  capacity             ; Evacuee capacity
  evacuee_count        ; Evacuee pedestrian count if it is a shelter, else -9999
  evacuee_count_list   ; Evacuee cont per tick
]

roads-own [
  road_length        ; Road length in meters
  road_width         ; Road width in meters
  slope              ; Road slope in meters
]

pedestrians-own[
  id                  ; Pedestrian id
  init_x              ; Initial position
  init_y              ; Initial position
  age                 ; Age
  depar_time          ; Departure time
  base_speed          ; Average speed according to pedestrian age
  speed               ; Current speed
  slope_factor        ; TODO
  density_factor      ; TODO
  decision            ; "horizontal": Horizontal, "ver": Vertical or "no": Not willing to evacuate
  route               ; List of "who" from nodes remaining to reach the shelter
  goal_shelter_id     ; Goal shelter OSM id of their evacuation route
  current_node        ; Current node of their evacuation route
  next_node           ; Next node of their evacuation route
  started?            ; True if the pedestrian has started to evacuate
  moving?             ; True if the pedestrian is evacuating (and their is not dead)
  in_node?            ; True if the pedestrian is on a node (in order to get their next node)
  evacuated?          ; True if the pedestrian reach their goal shelter
  dead?               ; True if the pedestrian is on a patch with flow_depth >= flow_depth_threshold
  total_distance      ; Total distance walked
  end_time            ; Ticks when pedestrian has reached a shelter or has died
]


globals [
  config                      ; Configuration table readed from a JSON file
  absolute_data_path          ; Data Path
  absolute_output_path        ; Output Path
  max_seconds                 ; Maximum seconds per simulation
  urban_network_dataset       ; Urban network edges dataset
  node_dataset                ; Urban network nodes dataset
  shelter_dataset             ; Shelters dataset
  agent_distribution_dataset  ; Agent distribution dataset
  tsunami_sample_dataset      ; Sample tsunami inundation raster dataset
  min_flow_depth              ; Minimum flow depth for tsunami color palette
  max_flow_depth              ; Maximum flow depth for tsunami color palette

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;;;;;;;; CONVERSION RATIOS ;;;;;;;;;
  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  meters_per_patch      ; Meters per patch
  seconds_per_tick      ; Seconds per tick

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;;;;;;;;;     DENSITY     ;;;;;;;;;;
  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  pedestrian_counting_radius  ; Radius for density counting
  min_density_factor          ; Minimum density factor

  ;;;;;;;;;;;;
  ;; OTHERS ;;
  ;;;;;;;;;;;;
  reach_node_tolerance        ; Float point tolerance for arriving at nodes
  shelters_agenset            ; Agenset of shelters
  pedestrian_status_list      ; For making output
  aux
]


to-report get-node [node_id]
  ; Return who number based on node id
  let who_number [who] of nodes with [id = node_id]
  ifelse length who_number = 1 [
    report node item 0 who_number
  ][
    report nobody
  ]
end


to-report get-who-node [node_id]
  report [who] of get-node node_id
end


to-report get-road [node1 node2]
  ; Return road according start and end nodes
  let node1_who [who] of node1
  let node2_who [who] of node2
  report road node1_who node2_who
end


to initial-values
  ; Initial values based on configuration file
  set absolute_data_path (word pathdir:get-model-path pathdir:get-separator data_path)
  set config (table:from-json-file (word absolute_data_path pathdir:get-separator "config.json"))
  set seconds_per_tick (table:get-or-default config "seconds_per_tick" 10)
  set max_seconds (table:get-or-default config "max_seconds" 3600)
  ; Tsunami inundation scale
  set min_flow_depth (table:get config "min_flow_depth")
  set max_flow_depth (table:get config "max_flow_depth")
  ; Outputs
  set pedestrian_status_list (list ["moving" "evacuated" "dead"])
end


to read-gis-files
  gis:load-coordinate-system (word absolute_data_path pathdir:get-separator "urban_network" pathdir:get-separator "urban_network.prj")
  set urban_network_dataset gis:load-dataset (word absolute_data_path pathdir:get-separator "urban_network" pathdir:get-separator "urban_network.shp")
  set node_dataset gis:load-dataset (word absolute_data_path pathdir:get-separator "urban_network" pathdir:get-separator "nodes.shp")
  set shelter_dataset gis:load-dataset (word absolute_data_path pathdir:get-separator "shelters" pathdir:get-separator "shelters.shp")
  set agent_distribution_dataset gis:load-dataset (word absolute_data_path pathdir:get-separator "agent_distribution" pathdir:get-separator "agent_distribution.shp")
  set tsunami_sample_dataset gis:load-dataset (word absolute_data_path pathdir:get-separator "tsunami_inundation" pathdir:get-separator "sample.asc")

  let world_envelope (
    gis:envelope-union-of
      (gis:envelope-of urban_network_dataset)
      (gis:envelope-of node_dataset)
      (gis:envelope-of shelter_dataset)
      (gis:envelope-of agent_distribution_dataset)
      (gis:envelope-of tsunami_sample_dataset)
  )
  gis:set-world-envelope-ds world_envelope                                                                ; transformation from real world to netlogo world
  ; Transform parameters from meters to patchs
  let gis_world_width (item 1 world_envelope - item 0 world_envelope)                                     ; real world width in meters
  let gis_world_height (item 3 world_envelope - item 2 world_envelope)                                    ; real world height in meters
  set meters_per_patch max (list (gis_world_height / world-width) (gis_world_height / world-height))
  set pedestrian_counting_radius (pedestrian_counting_radius_meters / meters_per_patch)
  let reach_node_tolerance_meters (table:get-or-default config "reach_node_tolerance" 0.05)
  set reach_node_tolerance (reach_node_tolerance_meters / meters_per_patch)
  let min_density_factor_meters (table:get-or-default config "min_density_factor_meters" 0.1)
  set min_density_factor (min_density_factor_meters / meters_per_patch)
end


to load-nodes
  ; Load urban network nodes
  ask nodes [die]
  gis:create-turtles-from-points node_dataset nodes [
    set size 1
    set color white
    set shape "circle"
    set shelter? false
    set evac_type 0
  ]
  let horizontal_routes table:from-json-file ( word
    absolute_data_path
    pathdir:get-separator
    "urban_network"
    pathdir:get-separator
    "horizontal_evacuation_routes.json"
  )
  let vertical_routes table:from-json-file ( word
    absolute_data_path
    pathdir:get-separator
    "urban_network"
    pathdir:get-separator
    "vertical_evacuation_routes.json"
  )
  ask nodes [
    let horizontal_route_id table:get horizontal_routes (word id)
    let vertical_route_id table:get vertical_routes (word id)
    set horizontal_route map get-who-node horizontal_route_id
    set vertical_route map get-who-node vertical_route_id
  ]
  output-print "Nodes Loaded"
end


to load-shelters
  ; Load temporarily shelter dataset in order to give their attributes to shelter nodes
  ask nodes [
    foreach gis:feature-list-of shelter_dataset [ i ->
      let i_shelter_id ( gis:property-value i "id" )
      if id = i_shelter_id [
        set color green
        set shape "square"
        set size 5
        set shelter? true
        set evac_type ( gis:property-value i "evac_type" )
        set capacity 1000000  ; TODO
        set evacuee_count 0
        set evacuee_count_list []
      ]
    ]
  ]
  set shelters_agenset nodes with [shelter?]
  output-print "Shelters Loaded"
end


to load-roads
  ; Load road as links
  ask roads [die]
  foreach gis:feature-list-of urban_network_dataset [ i ->
    let from_node get-node gis:property-value i "from_id"
    let to_node get-node gis:property-value i "to_id"
    ask from_node [
      create-road-to to_node [
        set road_length ((gis:property-value i "length") / meters_per_patch)
        set road_width ((gis:property-value i "width") / meters_per_patch)
        set slope gis:property-value i "slope"
        ;set shape "line"
      ]
    ]
  ]
  output-print "Roads Loades"
end


to update-tsunami-inundation
  ; load tsunamis raster
  let seconds int(ticks * seconds_per_tick)
  if seconds mod seconds_per_tick = 0 [
    let tsunami_filename (word absolute_data_path pathdir:get-separator "tsunami_inundation" pathdir:get-separator seconds ".asc")
    let tsunami_dataset gis:load-dataset tsunami_filename
    ; gis:set-world-envelope (gis:envelope-of inundation)  ; check this!
    gis:apply-raster tsunami_dataset flow_depth
    ; ask patches with [flow_depth = -9999][set flow_depth 0]  ; TODO: change -9999
    ask patches with [not ((flow_depth <= 0) or (flow_depth >= 0))][set flow_depth 0]
    ask patches [
      set pcolor scale-color blue flow_depth min_flow_depth max_flow_depth
    ]
  ]
end


to load-pedestrians
  ; load pedestrian distribution
  ask pedestrians [ die ]
  gis:create-turtles-from-points-manual agent_distribution_dataset pedestrians [["speed" "base_speed"]] [
    set size 1.5
    set shape "circle"
    set current_node nobody
    set started? false
    set moving? false
    set in_node? false
    set evacuated? false
    set dead? false
    set slope_factor 1 ; TODO
    set density_factor 1  ; TODO
    set depar_time (depar_time / seconds_per_tick)                     ; cast seconds to ticks
    set base_speed (base_speed * seconds_per_tick / meters_per_patch)  ; cast meter/second to patch/tick
    set total_distance 0
    set end_time 0
  ]
  make-evacuation-decision
  output-print "Pedestrians Loaded"
end


to make-evacuation-decision
  ask pedestrians [
    let rnd_evacuation_willingness random-float 1
    ifelse ( rnd_evacuation_willingness <= evacuation_willingness_prob )
    [
      let rnd_vert_evacuation_willingness random-float 1
      ifelse ( rnd_vert_evacuation_willingness <= vert_evacuation_willingness_prob )
      [
        set decision "vertical"
        set color orange
      ]
      [
        set decision "horizontal"
        set color yellow
      ]
    ]
    [
      set decision "no"
      set color brown
      set depar_time ( max_seconds / seconds_per_tick + 1 )  ; Inifinite departure time
    ]
  ]

end


to start-to-evacuate
  ; Validate if pedestrian must start to evacuate according their departure time
  ask pedestrians with [not started? and depar_time <= ticks]
    [
      set next_node min-one-of nodes [distance myself]
      set route ( get-route next_node decision )
      ;set goal_shelter_id ( ifelse-value (is-list? route) [ last route ][ 0 ] )
      set goal_shelter_id (last route )
      set started? true
      set moving? true
      set in_node? true  ; dummy node in order to start evacuation
  ]
end


to update-route
  ; Update next node, heading and slope factor of of each pedestrian
  ask pedestrians with [ moving? and in_node? ][
    get-next-node
    if next_node != nobody [
      set heading towards next_node
      set in_node? false
      update-slope-factor
    ]
  ]
end

to get-next-node
  let rnd_confusion_ratio random-float 1
  ifelse ( rnd_confusion_ratio >= confusion_ratio or current_node = nobody)
  [
    set next_node ( node first route )
    set route ( but-first route )
  ]
  [
    set next_node one-of [out-road-neighbors] of current_node
    set route ( get-route next_node decision )
  ]  ; pedestrian picks any road
end


to-report get-route [from_node evacuation_decision ]
  (
    ifelse
      evacuation_decision = "horizontal" [ report [horizontal_route] of from_node ]
      evacuation_decision = "vertical"   [ report [vertical_route] of from_node ]
                                         [ report [] ]
   )
end


to move-pedestrians
  ; Move pedestrians updating their speed
  ask pedestrians with [moving? and not in_node?][
    ; update-density-factor  ; CHECK!
    ; Current speed updated by slope and density factors
    set speed (base_speed * slope_factor * density_factor)
    ; If next node is to close then the pedestrian reach the next node
    let distance_to_move min (list speed (distance next_node))
    fd distance_to_move
    set total_distance (total_distance + distance_to_move)
    ; Check if pedestrian has reached next node
    let distance_to_next_node distance next_node
    if (distance_to_next_node < reach_node_tolerance ) [
      fd distance_to_next_node
      set in_node? true
      set current_node next_node
      set total_distance (total_distance + distance_to_next_node)
      ; Check if next node is a shelter
      if ( [shelter?] of current_node ) [
        ifelse ( [evacuee_count < capacity] of current_node ) [ mark-evacuated ][ update-backup-route ]
      ]
    ]
  ]
end


to update-slope-factor
  ; Update slope factor according to road slope
  if current_node != nobody [
    let slope_road ( [slope] of get-road current_node next_node )
    set slope_factor ( precision (exp(-3.5 * abs(slope_road + 0.05) + 0.175)) 3 )
  ]
end


to update-density-factor
  ; Update density factor according to pedestrians around them
  let current_route_width ifelse-value (current_node != nobody and next_node != nobody)
    [[road_width] of get-road current_node next_node]
    [ 6 / meters_per_patch]  ; when pedestrian is not walking over a road
  ; Count pedestrians around them
  ; TODO: update units of ticks and depar_time
  let n_pedestrians_within_radius (count ((pedestrians with [moving?]) in-radius (pedestrian_counting_radius)))
  let pedestrian_density (n_pedestrians_within_radius / (2 * pedestrian_counting_radius * current_route_width))
  ifelse pedestrian_density = 0
    [ set density_factor 1 ]
    [ ifelse pedestrian_density < jammed_pedestrian_density
        [set density_factor precision (1 - EXP(-1.913 * (1 / pedestrian_density - 1 / jammed_pedestrian_density))) 3]
        [set density_factor min_density_factor]
    ]
end

to update-backup-route
  print "Update backup route!"
end

to mark-evacuated
  ; Mark pedestrian as evacuated
  set evacuated? true
  set moving? false
  set end_time ticks
  set color green
  ask current_node [set evacuee_count (evacuee_count + 1)]
end


to update-dead-pedestrians
  ; Update if pedestrians are alive or not
  ask pedestrians with [not dead? and not evacuated?][
    let flow_depth_here [flow_depth] of patch-here
    if flow_depth_here >= flow_depth_threshold
      [
        set moving? false
        set dead? true
        set end_time ticks
        set color red
        set shape "x"
      ]
    ]
end


to update-evacuee-count-list
  ; Update evacuee count list of each shelter in each tick
  ask shelters_agenset [set evacuee_count_list lput evacuee_count evacuee_count_list ]
end


to update-pedestrian-status-list
  let n_moving count pedestrians with [moving?]
  let n_evacuated count pedestrians with [evacuated?]
  let n_dead count pedestrians with [dead?]
  set pedestrian_status_list lput (list n_moving n_evacuated n_dead) pedestrian_status_list
end


to write-output
  set absolute_output_path ( word absolute_data_path pathdir:get-separator "output" )
  if behaviorspace-experiment-name != "" [
    set absolute_output_path ( word absolute_output_path pathdir:get-separator behaviorspace-experiment-name pathdir:get-separator behaviorspace-run-number )
  ]
  if not pathdir:isDirectory? absolute_output_path [ pathdir:create absolute_output_path ]
  output-print ( word "Output path: " absolute_output_path)
  ; Shelters output
  let shelter_evacuation_output (word absolute_output_path pathdir:get-separator "shelters_evacuation.csv")
  if file-exists? shelter_evacuation_output [ file-delete shelter_evacuation_output ]
  let shelter_evacuation_matrix matrix:from-row-list [evacuee_count_list] of turtle-set sort shelters_agenset
  let shelter_osm_id (list map [ x -> [id] of x ] sort shelters_agenset)
  let shelter_evacuation_list sentence shelter_osm_id matrix:to-column-list shelter_evacuation_matrix
  csv:to-file shelter_evacuation_output shelter_evacuation_list
  output-print "Shelters output has been successfully written"
  ; Pedestrian-tick output
  let pedestrian_tick_output (word absolute_output_path pathdir:get-separator "pedestrian_ticks.csv")
  if file-exists? pedestrian_tick_output [ file-delete pedestrian_tick_output ]
  csv:to-file pedestrian_tick_output pedestrian_status_list
  output-print "Pedestrian status per tick output has been successfully written"
  ; Pedestrian output
  let pedestrian_output (word absolute_output_path pathdir:get-separator "pedestrians.csv")
  if file-exists? pedestrian_output [ file-delete pedestrian_output ]
  let pedestrian_output_list ( sentence
    [
      [
        "id"
        "decision"
        "init_x"
        "init_y"
        "age"
        "depar_time"
        "base_speed"
        "final_node"
        "total_distance"
        "end_time"
        "moving"
        "evacuated"
        "dead"
      ]
    ]
    [
      (list
        id
        decision
        init_x
        init_y
        age
        depar_time
        base_speed
        ifelse-value (current_node != nobody) [[id] of current_node] [""]
        total_distance
        end_time
        moving?
        evacuated?
        dead?
      )
    ] of pedestrians
  )
  csv:to-file pedestrian_output pedestrian_output_list
  output-print "Pedestrian output has been successfully written"
  ; Simulation Output
  let simulation_output (word absolute_output_path pathdir:get-separator "scenario_output.txt")
  if file-exists? simulation_output [ file-delete simulation_output ]
  export-output simulation_output
end


to setup
  clear-all
  reset-ticks
  reset-timer
  initial-values
  read-gis-files
  load-nodes
  load-shelters
  load-roads
  load-pedestrians
  output-print "Setup done"
end


to go
  if ticks > max_seconds / seconds_per_tick ; stopper
    [
      write-output
      output-print (word "Simulation total time: " timer " seconds.")
      stop
    ]
  update-tsunami-inundation
  update-dead-pedestrians
  start-to-evacuate
  update-route
  move-pedestrians
  update-evacuee-count-list
  update-pedestrian-status-list
  tick
end
@#$#@#$#@
GRAPHICS-WINDOW
171
10
861
701
-1
-1
3.393035
1
10
1
1
1
0
0
0
1
-100
100
-100
100
0
0
1
ticks
30.0

BUTTON
6
10
69
43
NIL
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
95
10
158
43
NIL
go
T
1
T
OBSERVER
NIL
NIL
NIL
NIL
0

PLOT
887
14
1413
250
Pedestrians
time
total
0.0
10.0
0.0
10.0
true
true
"" ""
PENS
"moving" 1.0 0 -16777216 true "" "plot count pedestrians with [moving?]"
"evacuated" 1.0 0 -13840069 true "" "plot count pedestrians with [evacuated?]"
"dead" 1.0 0 -2674135 true "" "plot count pedestrians with [dead?]"

INPUTBOX
4
56
159
116
data_path
scenario_test
1
0
String

INPUTBOX
4
126
158
186
flow_depth_threshold
0.1
1
0
Number

INPUTBOX
4
197
157
257
jammed_pedestrian_density
5.4
1
0
Number

INPUTBOX
3
273
158
333
pedestrian_counting_radius_meters
0.3
1
0
Number

INPUTBOX
4
345
159
405
confusion_ratio
0.1
1
0
Number

INPUTBOX
4
417
159
477
evacuation_willingness_prob
0.9
1
0
Number

INPUTBOX
4
496
159
556
vert_evacuation_willingness_prob
0.2
1
0
Number

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
NetLogo 6.2.1
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
<experiments>
  <experiment name="test_experiment" repetitions="1" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;scenario_test&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
      <value value="0.2"/>
      <value value="0.3"/>
      <value value="0.4"/>
      <value value="0.5"/>
    </enumeratedValueSet>
  </experiment>
</experiments>
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
