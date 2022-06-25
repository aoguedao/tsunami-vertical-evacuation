extensions [
  csv
  gis
  matrix
  pathdir
  py
  table
  ; profiler
]

breed [ nodes node ]
breed [ pedestrians pedestrian ]
directed-link-breed [ roads road ]

patches-own [
  flow_depth            ; Tsunami flow_depth  // or depth?
  vertical_evacuation?  ; True if pedestrian can evacuate vertically
  init_pedestrians      ; Number of initial pedestrian on each patch
]

nodes-own[
  id                   ; Open Street Map node id
  shelter?             ; True if it is a shelter
  evac_type            ; Evacuation shelter type if it is a shelter, else 0
  capacity             ; Evacuee capacity
  evacuee_count        ; Evacuee pedestrian count if it is a shelter, else -9999
  evacuee_count_list   ; Evacuee cont per tick
]

roads-own [
  road_length        ; Road length in meters
  slope              ; Road slope
  sidewalks          ; Number of sidewalks
  sidewalk_width     ; Width of each sidewalk in meters
]

pedestrians-own[
  init_x              ; Initial position
  init_y              ; Initial position
  age                 ; Age
  depar_time          ; Departure time
  base_speed          ; Average speed according to pedestrian age
  speed               ; Current speed
  slope_factor        ; Slope factor for modifiying pedestrian speed
  decision            ; "horizontal": Horizontal, "ver": Vertical or "no": Not willing to evacuate
  init_decision       ; Initial decision, for statistics purposes
  route               ; List of "who" from nodes remaining to reach the shelter
  goal_shelter_id     ; Goal shelter OSM id of their evacuation route
  current_node        ; Current node of their evacuation route
  next_node           ; Next node of their evacuation route
  current_road        ; Road where pedestrian is on
  road_lane           ; Road lane
  started?            ; True if the pedestrian has started to evacuate
  moving?             ; True if the pedestrian is evacuating (and their is not dead)
  in_node?            ; True if the pedestrian is on a node (in order to get their next node)
  evacuated?          ; True if the pedestrian reach their goal shelter
  dead?               ; True if the pedestrian is on a patch with flow_depth >= flow_depth_threshold
  total_distance      ; Total distance walked
  end_time            ; Ticks when pedestrian has reached a shelter or has died
]


globals [
  config                             ; Configuration table readed from a JSON file
  absolute_data_path                 ; Data Path
  absolute_output_path               ; Output Path
  max_seconds                        ; Maximum seconds per simulation
  urban_network_dataset              ; Urban network edges dataset
  vertical_evacuation_mask_dataset   ; Area from where pedestrians can evacuate vertically
  node_dataset                       ; Urban network nodes dataset
  shelter_dataset                    ; Shelters dataset
  population_areas_dataset           ; Population areas dataset
  horizontal_routes                  ; List of horizontal routes for each node
  vertical_routes                    ; List of vertical routes for each node
  alternative_shelter_routes         ; List routes for each shelter
  tsunami_sample_dataset             ; Sample tsunami inundation raster dataset
  min_flow_depth                     ; Minimum flow depth for tsunami color palette
  max_flow_depth                     ; Maximum flow depth for tsunami color palette
  speed_age_table                    ; Speed-Age relationship for pedestrians
  population_age_table               ; Population-Age table of pedestrian
  population_age_cdf                 ; Cumulative density function of pedestrians
  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;;;;;;;; CONVERSION RATIOS ;;;;;;;;;
  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  meters_per_patch                   ; Meters per patch
  seconds_per_tick                   ; Seconds per tick
  ;;;;;;;;;;;;
  ;; OTHERS ;;
  ;;;;;;;;;;;;
  shelters_agenset                   ; Agenset of shelters (nodes with property shelte? true)
  nodes_id_table                     ; Table where keys are OSM id (or any other id) from each node and value is the node itself
  pedestrian_status_list             ; For making output of pedestrian status in each tick
  reach_node_tolerance               ; Float point tolerance for arriving at nodes
  alternate_shelter_radius           ; For looking an alternative route if vertical shelters are full
]


to-report get-node [node_id]
  ; Return node (turtle) based on node id (from dataset).
  report table:get-or-default nodes_id_table node_id nobody
end


to-report get-who-node [node_id]
  ; Return "who" id based on node id (from dataset).
  report [who] of table:get-or-default nodes_id_table node_id nobody
end


to-report rayleigh-random [sigma]
  ; Return a Rayleigh distribution value based on parameter sigma.
  report sqrt((- ln(1 - random-float 1 ))*(2 *(sigma ^ 2)))
end


to make-age-population-cdf
  ; Cumulative distribution function of population by age.
  set population_age_cdf table:make
  table:remove population_age_table "age"
  let total_population ( sum(table:values population_age_table) )
  let age_cum_population 0
  (
    foreach sort table:keys population_age_table [ age_key ->
      let age_population table:get population_age_table age_key
      set age_cum_population ( age_cum_population + age_population )
      table:put population_age_cdf ( age_cum_population / total_population ) age_key
    ]
  )
end


to-report simulate-age
  ; Return age based on the cumulative distribution function.
  let u random-float 1
  report table:get population_age_cdf min(filter [ i -> i >= u ] table:keys population_age_cdf)
end


to-report get-speed [pedestrian_age]
  ; Return pedestrian speed according to their age.
  (
    ifelse
    (pedestrian_age <= 5)  [ report table:get speed_age_table 5 ]
    (pedestrian_age >= 80) [ report table:get speed_age_table 80 ]
                           [ report table:get speed_age_table pedestrian_age ]
  )

end


to initial-values
  ; Initial values based on configuration file
  set absolute_data_path (word pathdir:get-model-path pathdir:get-separator data_path)
  let config_filepath (word
    absolute_data_path
    pathdir:get-separator
    "tsunami_inundation"
    pathdir:get-separator
    tsunami_scenario
    pathdir:get-separator
    "config.json"
  )
  set config (table:from-json-file config_filepath )
  set seconds_per_tick (table:get config "seconds_per_tick")
  set max_seconds (table:get config "max_seconds")
  set min_flow_depth (table:get config "min_flow_depth") ;
  set max_flow_depth (table:get config "max_flow_depth")

  ; Output prints
  output-print ( word "[data_path]: " absolute_data_path )
  output-print ( word "[tsunami_scenario]: " tsunami_scenario )
  output-print ( word "[population_scenario]: " population_scenario )
  output-print ( word "[evacuation_route_type]: " evacuation_route_type )
  output-print ( word "[flow_depth_threshold]: " flow_depth_threshold )
  output-print ( word "[evacuation_willingness_prob]: " evacuation_willingness_prob )
  output-print ( word "[vert_evacuation_willingness_prob]: " vert_evacuation_willingness_prob )
  output-print ( word "[confusion_ratio]: " confusion_ratio )
  output-print ( word "[departure_time_mean_in_sec]: " departure_time_mean_in_sec )
  output-print ( word "[alternate_shelter_radius_meters]: " alternative_shelter_radius_meters )
  output-print ( word "[config_filepath]: " config_filepath )
  output-print ( word "[seconds_per_tick]: " seconds_per_tick  )
  output-print ( word "[max_seconds]: " max_seconds )
  output-print ( word "[min_flow_depth]: " min_flow_depth )
  output-print ( word "[max_flow_depth]: " max_flow_depth )
  ; Outputs
  set pedestrian_status_list (list ["moving" "evacuated" "dead"])  ; Store pedestrian status
  set absolute_output_path ( word absolute_data_path pathdir:get-separator "output" )
  if behaviorspace-experiment-name != "" [
    set absolute_output_path ( word absolute_output_path pathdir:get-separator behaviorspace-experiment-name pathdir:get-separator behaviorspace-run-number )
  ]
  if not pathdir:isDirectory? absolute_output_path [ pathdir:create absolute_output_path ]
  output-print ( word "[absolute_output_path]: " absolute_output_path)
  output-print ( word date-and-time " - Initial values loaded" )
end


to read-gis-files
  gis:load-coordinate-system (word absolute_data_path pathdir:get-separator "tsunami_inundation" pathdir:get-separator tsunami_scenario pathdir:get-separator "0.prj")
  set tsunami_sample_dataset gis:load-dataset (word absolute_data_path pathdir:get-separator "tsunami_inundation" pathdir:get-separator tsunami_scenario pathdir:get-separator "0.asc")
  set urban_network_dataset gis:load-dataset (word absolute_data_path pathdir:get-separator "urban" pathdir:get-separator "urban_network.shp")
  set node_dataset gis:load-dataset (word absolute_data_path pathdir:get-separator "urban" pathdir:get-separator "urban_nodes.shp")
  set vertical_evacuation_mask_dataset gis:load-dataset (word absolute_data_path pathdir:get-separator "urban" pathdir:get-separator "vertical_evacuation_mask.shp")
  set shelter_dataset gis:load-dataset (word absolute_data_path pathdir:get-separator "shelters" pathdir:get-separator "shelters_node.shp")
  set population_areas_dataset gis:load-dataset (word absolute_data_path pathdir:get-separator "population" pathdir:get-separator population_scenario pathdir:get-separator "population_areas.shp")
  ; Resize netlogo world
  let world_columns ( gis:width-of tsunami_sample_dataset - 1 )
  let world_rows ( gis:height-of tsunami_sample_dataset  - 1 )
  resize-world 0 world_columns 0 world_rows
  ; Envelope
  let world_envelope ( gis:envelope-of tsunami_sample_dataset )  ; Envelope is given only by tsunami raster
  gis:set-world-envelope-ds world_envelope  ; Transformation from real world to netlogo world
  ; Transform parameters from meters to patchs
  let gis_world_width (item 1 world_envelope - item 0 world_envelope)  ; Real world width in meters
  let gis_world_height (item 3 world_envelope - item 2 world_envelope)  ; Real world height in meters
  set meters_per_patch max (list (gis_world_height / world-width) (gis_world_height / world-height))
  set reach_node_tolerance (0.2 / meters_per_patch)  ; 20 cm default
  set alternate_shelter_radius (alternative_shelter_radius_meters / meters_per_patch)
  ; Output printing
  output-print ( word "[meters_per_patch]: " meters_per_patch )
  output-print ( word "[reach_node_tolerance]: " reach_node_tolerance )
  output-print ( word "[alternate_shelter_radius]: " alternate_shelter_radius )
  output-print ( word date-and-time " - GIS files readed" )
  ; Apply vertical evacuation property to patches
  gis:apply-coverage vertical_evacuation_mask_dataset "VERT_EVAC" vertical_evacuation?
  ask patches with [vertical_evacuation? = 1] [set vertical_evacuation? true]
  if vert_evacuation_willingness_prob > 0 [
    gis:set-drawing-color 135
    gis:draw vertical_evacuation_mask_dataset 5
  ]
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
  set nodes_id_table table:make
  ask nodes [ table:put nodes_id_table id self ]
  output-print ( word date-and-time " - Nodes loaded" )
end


to load-shelters
  ; Load temporarily shelter dataset in order to give their attributes to shelter nodes
  ask nodes [
    foreach gis:feature-list-of shelter_dataset [ i ->
      let i_shelter_id ( gis:property-value i "id" )
      if id = i_shelter_id [
        set color green
        set shape "square"
        set size 12
        set shelter? true
        set capacity ( gis:property-value i "capacity" )
        set evac_type ( gis:property-value i "evac_type" )
        set evacuee_count 0
        set evacuee_count_list []
      ]
    ]
  ]
  set shelters_agenset ( nodes with [shelter?] )
  output-print ( word date-and-time " - Sheltersloaded" )
end


to load-roads
  ; Load road as links
  ask roads [die]
  foreach gis:feature-list-of urban_network_dataset [ i ->
    let from_node ( get-node gis:property-value i "from_id" )
    let to_node ( get-node gis:property-value i "to_id" )
    ask from_node [
      create-road-to to_node [
        set road_length ((gis:property-value i "length") / meters_per_patch)
        set slope gis:property-value i "slope"
        set sidewalks gis:property-value i  "sidewalks"
        set sidewalk_width ((gis:property-value i "sd_width") / meters_per_patch)
        set thickness 1.5
      ]
    ]
  ]
  output-print ( word date-and-time " - Roads loaded" )
end


to load-evacuation-routes
  ; Evacuation routes are json files where each key is the id of each node and values are a list of nodes id representing the route to a shelter.
  ; However, alternative shelter routes are multiples, from each vertical shelter to any other vertical shelter, then keys are "{id_shelter1}&{id_shelter2}"
  let horizontal_routes_tmp table:from-json-file ( word
    absolute_data_path
    pathdir:get-separator
    "evacuation_routes"
    pathdir:get-separator
    evacuation_route_type
    pathdir:get-separator
    "horizontal_evacuation_routes.json"
  )
  let vertical_routes_tmp table:from-json-file ( word
    absolute_data_path
    pathdir:get-separator
    "evacuation_routes"
    pathdir:get-separator
    evacuation_route_type
    pathdir:get-separator
    "vertical_evacuation_routes.json"
  )
  let alternative_shelter_routes_tmp table:from-json-file ( word
    absolute_data_path
    pathdir:get-separator
    "evacuation_routes"
    pathdir:get-separator
    evacuation_route_type
    pathdir:get-separator
    "alternative_evacuation_routes.json"
  )
  ; Translate dataset id to "who" of each node
  set horizontal_routes table:make
  set vertical_routes table:make
  set alternative_shelter_routes table:make
  ask nodes [
    table:put horizontal_routes (who) (map get-who-node table:get horizontal_routes_tmp (word id))
    table:put vertical_routes (who) (map get-who-node table:get vertical_routes_tmp (word id))
  ]
  ask shelters_agenset with [evac_type = "vertical"][
    let origin_who who
    let origin_id id
    foreach [self] of shelters_agenset with [( evac_type = "vertical" ) and ( who != origin_who )] [ target_shelter ->
      let target_who ( [who] of target_shelter )
      let target_id ( [id] of target_shelter )
      let origin_target_who ( word origin_who "&" target_who )
      let origin_target_id ( word origin_id "&" target_id )
      table:put alternative_shelter_routes (origin_target_who) (map get-who-node table:get alternative_shelter_routes_tmp origin_target_id )
    ]
  ]
  output-print ( word date-and-time " - Evacuation Routes Loaded" )
end


to update-tsunami-inundation
  ; Load tsunamis raster in each tick.
  let seconds int(ticks * seconds_per_tick)
  let tsunami_dataset gis:load-dataset ( word
    absolute_data_path
    pathdir:get-separator
    "tsunami_inundation"
    pathdir:get-separator
    tsunami_scenario
    pathdir:get-separator
    seconds
    ".asc"
  )
  ; Apply tsunami raster to flow_depth property
  gis:apply-raster tsunami_dataset flow_depth
  ask patches with [not ((flow_depth <= 0) or (flow_depth >= 0))][set flow_depth 0]
  ask patches [ set pcolor scale-color blue flow_depth 0 max_flow_depth ]
end


to load-pedestrians
  ; Load pedestrian distribution
  ask pedestrians [ die ]
  set population_age_table table:from-list (
    csv:from-file (word absolute_data_path pathdir:get-separator "population" pathdir:get-separator "population_age.csv")
  )
  set speed_age_table table:from-list (
    csv:from-file (word absolute_data_path pathdir:get-separator "population" pathdir:get-separator "speed_age.csv")
  )
  make-age-population-cdf
  let departure_time_mean (departure_time_mean_in_sec / seconds_per_tick)
  foreach gis:feature-list-of population_areas_dataset [ row ->
    let n gis:property-value row "population"
    gis:create-turtles-inside-polygon row pedestrians (n / 100 ) [  ; You can change this if you want to simulate with few pedestrians
      set size 6
      set shape "circle"
      set init_x xcor
      set init_y ycor
      set age simulate-age
      set base_speed ( ( get-speed age ) * seconds_per_tick / meters_per_patch)
      set depar_time ( (rayleigh-random departure_time_mean_in_sec) / seconds_per_tick )
      set current_node nobody
      set started? false
      set moving? false
      set in_node? false
      set evacuated? false
      set dead? false
      set slope_factor 1
      set speed 0
      set total_distance 0
      set end_time 0
    ]
  ]
  make-evacuation-decision
  ask patches [set init_pedestrians (count turtles-here)]  ; Initial count of pedestrians in each patch
  output-print ( word date-and-time " - Pedestrians Loaded" )
  ; Store initial distribution
  ; let initial_pedestrian_distribution_filepath (word absolute_output_path pathdir:get-separator "initial_pedestrian_distribution.shp")
  ; if file-exists? initial_pedestrian_distribution_filepath [ file-delete initial_pedestrian_distribution_filepath ]
  ; let initial_pedestrian_distribution ( gis:turtle-dataset pedestrians )
  ; gis:store-dataset initial_pedestrian_distribution initial_pedestrian_distribution_filepath
  ; output-print ( word date-and-time " - Initial pedestrian distribution has been successfully written" )
end


to make-evacuation-decision
  ; Each pedestrian should decide if they is going to evacuate (horizontally or vertically) or not.
  ask pedestrians [
    let rnd_evacuation_willingness random-float 1  ; Random number for evacuation willigness
    ifelse ( rnd_evacuation_willingness <= evacuation_willingness_prob )
    [
      let rnd_vert_evacuation_willingness random-float 1  ; Random number for vertical evacuation
      ifelse ( ( rnd_vert_evacuation_willingness <= vert_evacuation_willingness_prob ) and ( vertical_evacuation? = true ) )
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
      set depar_time ( max_seconds / seconds_per_tick + 1 )  ; Infinite departure time
    ]
    set init_decision decision
  ]
  output-print ( word date-and-time " - Pedestrians have made their evacuation decision" )
end


to start-to-evacuate
  ; Validate if pedestrian must start to evacuate according their departure time
  ask pedestrians with [not started? and not dead? and depar_time <= ticks]
    [
      set next_node ( min-one-of nodes [distance myself] )
      set route ( get-route next_node decision )
      set goal_shelter_id (last route )
      set started? true
      set moving? true
      set in_node? true  ; Dummy node in order to start evacuation
  ]
end


to update-route
  ; Update next node, heading and slope factor of of each pedestrian
  ask pedestrians with [ moving? and in_node? ][
    set-next-node
    set-current-road
    if next_node != nobody [
      set heading towards next_node
      set in_node? false
      set road_lane ifelse-value (current_road != nobody ) [ (random [sidewalks] of current_road) + 1] [ 1 ]
      update-slope-factor
    ]
  ]
end


to set-next-node
  let rnd_confusion_ratio random-float 1  ; Random number for taking a wrong route
  ifelse ( ( rnd_confusion_ratio >= confusion_ratio ) or ( current_node = nobody ) )
  [
    ; Pedestrian follows his original route
    set next_node ( node first route )
    set route ( but-first route )
  ]
  [
    ; Pedestrian got confused and pick a random node connected to his current node by a road.
    set next_node one-of [out-road-neighbors] of current_node
    set route ( get-route next_node decision )
    set goal_shelter_id (last route )
  ]
end


to-report get-route [from_node evacuation_decision ]
  ; Return route according pedestrian decision
  (
    ifelse
    evacuation_decision = "horizontal" [ report table:get horizontal_routes ( [who] of from_node ) ]
    evacuation_decision = "vertical"   [ report table:get vertical_routes ( [who] of from_node ) ]
                                       [ report [] ]
   )
end


to set-current-road
  ; Set current road of pedestrian while their are evacuating.
  ifelse ( current_node != nobody and next_node != nobody)
  [ set current_road (road ([who] of current_node) ([who] of next_node)) ]
  [ set current_road nobody ]
end


to move-pedestrians
  ; Move pedestrians and updating their speed.
  update-speed  ; Current speed updated by slope and density factors
  ask pedestrians with [moving? and not in_node?][
    ; If next node is to close then the pedestrian reach the next node
    let distance_to_move min (list speed (distance next_node))
    fd distance_to_move
    set total_distance (total_distance + distance_to_move)
    check-reach-node
  ]
end


to update-slope-factor
  ; Update slope factor according to road slope.
  ; TODO: SOURCE
  if current_road != nobody [
    let slope_road ( [slope] of current_road )
    set slope_factor ( exp( -3.5 * abs( slope_road + 0.05 ) + 0.175 ) )
  ]
end


to update-speed
  ; Get pedestrian density.
  ; TODO: SOURCE
  ask pedestrians with [moving? and not in_node?][
    let slope_speed ( base_speed * slope_factor )
    let max_distance_to_move min (list slope_speed (distance next_node))
    let x1 ( xcor )
    let x2 ( max_distance_to_move * dx )
    let pedestrian_current_road ( current_road )
    let pedestrian_current_lane ( road_lane)
    let n_pedestrians_ahead (
      count pedestrians with [
        ( current_road = pedestrian_current_road )
        and ( road_lane = pedestrian_current_lane)
        and ( xcor >= x1 )
        and ( xcor <= x2 )
      ]
    )
    let current_width ifelse-value (current_road != nobody)
    [[sidewalk_width] of current_road]
    [ 3 / meters_per_patch]  ; When pedestrian is not walking over a sidewalk (3 meters by default)
    let pedestrian_density (n_pedestrians_ahead / (current_width * max_distance_to_move))
    set speed (speed-density slope_speed pedestrian_density )
  ]
end


to-report speed-density [speed_p density_p]
  ; Speed density curve
  ; Source: Goto
  let s ( speed_p * meters_per_patch / seconds_per_tick )
  let p ( density_p / meters_per_patch ^ 2 )
  let threshold ( 1 - 0.343347 * (s - 1.5) )
  (ifelse
    ( p <= threshold )          [ report s ]
    ( p > threshold and p <= 1) [ report -2.9125 * (p - 1.0)  + 1.5 ]   ; line slope (3.83 - 1.5) / (0.2 - 1.0)
    ( p > 1.0 and p <= 1.7)     [ report -1.071428 * (p - 1.0) + 1.5 ]  ; line slope : (1.5 - 0.75) / (1.0 - 1.7)
    ( p > 1.7 and p <= 6.0)     [ report -0.174418 * (p - 6.0) ]        ; line slope : 0.75 / (1.7 - 6.0)
                                [ report 0 ]
  )
end

to check-reach-node
  ; Check if pedestrian has reached next node.
  let distance_to_next_node distance next_node
  if (distance_to_next_node < reach_node_tolerance ) [
    fd distance_to_next_node
    set in_node? true
    set current_node next_node
    set total_distance (total_distance + distance_to_next_node)
    ; Check if next node is a shelter
    if ( [shelter?] of current_node) and ( ( [who] of current_node ) = goal_shelter_id )[
      ; Check if shelter is full
      ifelse ( [evacuee_count < capacity] of current_node ) [ mark-evacuated ][ alternate-route ]
    ]
  ]
end


to mark-evacuated
  ; Mark pedestrian as evacuated.
  set speed 0
  set evacuated? true
  set moving? false
  set end_time ticks
  set color green
  ask current_node [set evacuee_count (evacuee_count + 1)]
end


to alternate-route
  ; Look for an alternative route.
  ; The pedestrian will try to go to a horizontal shelter if there is any close to them,
  ; if not, it will go to another vertical shelter.
  ; But if there is no shelter in the fixed radius, then pedestrian will pick closest horizontal shelter.
  let who_of_current_shelter ( [who] of current_node )
  let shelters_in_radius ( shelters_agenset with [ who !=  who_of_current_shelter ] in-radius alternate_shelter_radius )  ; Radius is about pedestrian
  let vertical_shelters_in_radius ( shelters_in_radius with [ evac_type = "vertical" ] )
  let horizontal_shelters_in_radius ( shelters_in_radius with [ evac_type = "horizontal" ] )
  ifelse ( any? horizontal_shelters_in_radius ) [
    set decision "horizontal"
    set color yellow
    set route ( table:get horizontal_routes who_of_current_shelter )
  ]
  [
    ifelse ( any? vertical_shelters_in_radius) [
      let random_vertical_shelter ( [who] of (one-of vertical_shelters_in_radius) )
      let route_key ( word ( [who] of current_node ) "&" random_vertical_shelter )
      set route ( table:get alternative_shelter_routes route_key )
    ][
      set decision "horizontal"
      set color yellow
      set route ( table:get horizontal_routes who_of_current_shelter )
    ]
  ]
  set goal_shelter_id (last route )
end


to update-dead-pedestrians
  ; Update if pedestrians are alive or not
  ask pedestrians with [not dead? and not evacuated?][
    let flow_depth_here ( [flow_depth] of patch-here )
    if flow_depth_here >= flow_depth_threshold
      [
        set speed 0
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
  ; Update status list of pedestrian in each tick
  let n_moving count pedestrians with [moving?]
  let n_evacuated count pedestrians with [evacuated?]
  let n_dead count pedestrians with [dead?]
  set pedestrian_status_list lput (list n_moving n_evacuated n_dead) pedestrian_status_list
end


to write-output
  ; Shelter-tick output
  let shelter_evacuation_output (word absolute_output_path pathdir:get-separator "shelters_evacuation.csv")
  if file-exists? shelter_evacuation_output [ file-delete shelter_evacuation_output ]
  let shelter_evacuation_matrix matrix:from-row-list [evacuee_count_list] of turtle-set sort shelters_agenset
  let shelter_osm_id (list map [ x -> [id] of x ] sort shelters_agenset)
  let shelter_evacuation_list sentence shelter_osm_id matrix:to-column-list shelter_evacuation_matrix
  csv:to-file shelter_evacuation_output shelter_evacuation_list
  output-print (word date-and-time " - Shelters output has been successfully written" )

  ; Shelter output
  let shelters_output ( word absolute_output_path pathdir:get-separator "shelters.shp" )
  let shelters_gis_dataset ( gis:turtle-dataset nodes with [shelter?])
  if file-exists? shelters_output [ file-delete shelters_output ]
  gis:store-dataset shelters_gis_dataset shelters_output

  ; Pedestrian-tick output
  let pedestrian_tick_output (word absolute_output_path pathdir:get-separator "pedestrian_ticks.csv")
  if file-exists? pedestrian_tick_output [ file-delete pedestrian_tick_output ]
  csv:to-file pedestrian_tick_output pedestrian_status_list
  output-print (word date-and-time " - Pedestrian status per tick output has been successfully written" )

  ; Pedestrian output
  ask pedestrians [setxy init_x init_y]
  let pedestrians_output ( word absolute_output_path pathdir:get-separator "pedestrians.shp" )
  let pedestrians_gis_dataset ( gis:turtle-dataset pedestrians )
  if file-exists? pedestrians_output [ file-delete pedestrians_output ]
  gis:store-dataset pedestrians_gis_dataset pedestrians_output


  let pedestrian_output ( word absolute_output_path pathdir:get-separator "pedestrians.csv" )
  if file-exists? pedestrian_output [ file-delete pedestrian_output ]
  let pedestrian_output_list ( sentence
    [
      [
        "id"
        "init_decision"
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
        who
        init_decision
        decision
        init_x
        init_y
        age
        depar_time
        base_speed
        ifelse-value ( current_node != nobody ) [[id] of current_node] [""]
        total_distance
        end_time
        moving?
        evacuated?
        dead?
      )
    ] of pedestrians
  )
  csv:to-file pedestrian_output pedestrian_output_list
  output-print ( word date-and-time " - Pedestrian output has been successfully written" )

  ; Patches as raster
  let patch_dataset ( gis:patch-dataset init_pedestrians)
  let patch_output ( word absolute_output_path pathdir:get-separator "initial_population_distribution" )
  if file-exists? patch_output [ file-delete patch_output ]
  gis:store-dataset patch_dataset patch_output
  output-print ( word date-and-time " - Initial pedestrian distribution output has been successfully written" )

  ; World Output
  let world_output ( word absolute_output_path pathdir:get-separator "world_output.csv" )
  if file-exists? world_output [ file-delete world_output ]
  export-world world_output
  output-print ( word date-and-time " - NetLogo world has been successfully written" )

  ; View output
  let view_output ( word absolute_output_path pathdir:get-separator "initial_position_vs_final_status.png" )
  if file-exists? view_output [ file-delete view_output ]
  export-view view_output

  ; Simulation Output
  output-print ( word date-and-time " - Simulation has finalized and it took " timer " seconds (" (precision (timer / 60) 3 ) " minutes)." )
  let simulation_output ( word absolute_output_path pathdir:get-separator "scenario_output.txt" )
  if file-exists? simulation_output [ file-delete simulation_output ]
  export-output simulation_output
end


to setup
  clear-all
  reset-ticks
  reset-timer
  output-print (" --- Tsunami Vertical Evacuation Simulation ---" )
  if (behaviorspace-experiment-name != "") [
    output-print (word " Experiment: " behaviorspace-experiment-name " - Run " behaviorspace-run-number)
  ]
  initial-values
  output-print (word date-and-time " - Starting simulation" )
  read-gis-files
  load-nodes
  load-shelters
  load-roads
  load-evacuation-routes
  load-pedestrians
  output-print ( word date-and-time " - Setup has finalized succesfully" )
end


to go
  ifelse behaviorspace-experiment-name = "" [
    output-print ( word date-and-time " - Tick " ticks )
  ][
    output-print ( word date-and-time " - Run " behaviorspace-run-number " - Tick " ticks)

  ]
  update-tsunami-inundation
  update-dead-pedestrians
  start-to-evacuate
  update-route
  move-pedestrians
  update-evacuee-count-list
  update-pedestrian-status-list
  if ticks = (max_seconds / seconds_per_tick)
  [
    write-output
    stop
   ]
  tick
end


;to profile
;  setup                                                ; set up the model
;  profiler:start                                       ; start profiling
;  repeat (max_seconds / seconds_per_tick + 1) [ go ]   ; run something you want to measure
;  profiler:stop                                        ; stop profiling
;  csv:to-file "tve_profiler_data.csv" profiler:data    ; save the results
;  profiler:reset                                       ; clear the data
;end
@#$#@#$#@
GRAPHICS-WINDOW
170
10
1026
719
-1
-1
1.0
1
12
1
1
1
0
0
0
1
0
847
0
699
0
0
1
ticks
30.0

BUTTON
5
10
68
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
94
10
157
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
1133
11
1659
247
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
vina_del_mar
1
0
String

INPUTBOX
6
306
160
366
flow_depth_threshold
0.1
1
0
Number

INPUTBOX
3
536
158
596
confusion_ratio
0.1
1
0
Number

INPUTBOX
6
382
161
442
evacuation_willingness_prob
1.0
1
0
Number

INPUTBOX
6
461
161
521
vert_evacuation_willingness_prob
0.25
1
0
Number

INPUTBOX
1129
447
1284
507
alternative_shelter_radius_meters
500.0
1
0
Number

PLOT
1135
266
1659
417
Pedestrian speed
time
speed
0.0
10.0
0.0
1.0
true
false
"" ""
PENS
"mean" 1.0 0 -16777216 true "" "plot mean [speed] of pedestrians with [moving?]"

CHOOSER
3
187
160
232
population_scenario
population_scenario
"daytime" "nighttime"
0

CHOOSER
5
246
160
291
evacuation_route_type
evacuation_route_type
"shortest" "safest"
0

INPUTBOX
4
620
159
680
departure_time_mean_in_sec
180.0
1
0
Number

INPUTBOX
4
123
159
183
tsunami_scenario
tsunami_1730
1
0
String

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
  <experiment name="vina_del_mar_horizontal" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [moving?]</metric>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;vina_del_mar&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="tsunami_scenario">
      <value value="&quot;tsunami_1730&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="population_scenario">
      <value value="&quot;daytime&quot;"/>
      <value value="&quot;nighttime&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_route_type">
      <value value="&quot;shortest&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_willingness_prob">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="vert_evacuation_willingness_prob">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="confusion_ratio">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="departure_time_mean_in_sec">
      <value value="180"/>
      <value value="480"/>
      <value value="660"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="alternative_shelter_radius_meters">
      <value value="500"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="vina_del_mar_vertical" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [moving?]</metric>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;vina_del_mar&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="tsunami_scenario">
      <value value="&quot;tsunami_1730&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="population_scenario">
      <value value="&quot;daytime&quot;"/>
      <value value="&quot;nighttime&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_route_type">
      <value value="&quot;shortest&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_willingness_prob">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="vert_evacuation_willingness_prob">
      <value value="0.25"/>
      <value value="0.75"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="confusion_ratio">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="departure_time_mean_in_sec">
      <value value="180"/>
      <value value="480"/>
      <value value="660"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="alternative_shelter_radius_meters">
      <value value="500"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="vina_del_mar_test" repetitions="2" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [moving?]</metric>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;vina_del_mar&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="tsunami_scenario">
      <value value="&quot;tsunami_1730&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="population_scenario">
      <value value="&quot;daytime&quot;"/>
      <value value="&quot;nighttime&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_route_type">
      <value value="&quot;shortest&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_willingness_prob">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="vert_evacuation_willingness_prob">
      <value value="0.25"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="confusion_ratio">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="departure_time_mean_in_sec">
      <value value="180"/>
      <value value="540"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="alternative_shelter_radius_meters">
      <value value="500"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="vina_del_mar_vertical25_dt180" repetitions="10" sequentialRunOrder="false" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [moving?]</metric>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;vina_del_mar&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="tsunami_scenario">
      <value value="&quot;tsunami_1730&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="population_scenario">
      <value value="&quot;daytime&quot;"/>
      <value value="&quot;nighttime&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_route_type">
      <value value="&quot;shortest&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_willingness_prob">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="vert_evacuation_willingness_prob">
      <value value="0.25"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="confusion_ratio">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="departure_time_mean_in_sec">
      <value value="180"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="alternative_shelter_radius_meters">
      <value value="500"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="vina_del_mar_vertical25_dt480" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [moving?]</metric>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;vina_del_mar&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="tsunami_scenario">
      <value value="&quot;tsunami_1730&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="population_scenario">
      <value value="&quot;daytime&quot;"/>
      <value value="&quot;nighttime&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_route_type">
      <value value="&quot;shortest&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_willingness_prob">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="vert_evacuation_willingness_prob">
      <value value="0.25"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="confusion_ratio">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="departure_time_mean_in_sec">
      <value value="480"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="alternative_shelter_radius_meters">
      <value value="500"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="vina_del_mar_vertical25_dt660" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [moving?]</metric>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;vina_del_mar&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="tsunami_scenario">
      <value value="&quot;tsunami_1730&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="population_scenario">
      <value value="&quot;daytime&quot;"/>
      <value value="&quot;nighttime&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_route_type">
      <value value="&quot;shortest&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_willingness_prob">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="vert_evacuation_willingness_prob">
      <value value="0.25"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="confusion_ratio">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="departure_time_mean_in_sec">
      <value value="660"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="alternative_shelter_radius_meters">
      <value value="500"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="vina_del_mar_horizontal_dt180" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [moving?]</metric>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;vina_del_mar&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="tsunami_scenario">
      <value value="&quot;tsunami_1730&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="population_scenario">
      <value value="&quot;daytime&quot;"/>
      <value value="&quot;nighttime&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_route_type">
      <value value="&quot;shortest&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_willingness_prob">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="vert_evacuation_willingness_prob">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="confusion_ratio">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="departure_time_mean_in_sec">
      <value value="180"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="alternative_shelter_radius_meters">
      <value value="500"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="vina_del_mar_horizontal_dt480" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [moving?]</metric>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;vina_del_mar&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="tsunami_scenario">
      <value value="&quot;tsunami_1730&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="population_scenario">
      <value value="&quot;daytime&quot;"/>
      <value value="&quot;nighttime&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_route_type">
      <value value="&quot;shortest&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_willingness_prob">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="vert_evacuation_willingness_prob">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="confusion_ratio">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="departure_time_mean_in_sec">
      <value value="480"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="alternative_shelter_radius_meters">
      <value value="500"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="vina_del_mar_horizontal_dt660" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [moving?]</metric>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;vina_del_mar&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="tsunami_scenario">
      <value value="&quot;tsunami_1730&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="population_scenario">
      <value value="&quot;daytime&quot;"/>
      <value value="&quot;nighttime&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_route_type">
      <value value="&quot;shortest&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_willingness_prob">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="vert_evacuation_willingness_prob">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="confusion_ratio">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="departure_time_mean_in_sec">
      <value value="660"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="alternative_shelter_radius_meters">
      <value value="500"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="vina_del_mar_vertical75_dt180" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [moving?]</metric>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;vina_del_mar&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="tsunami_scenario">
      <value value="&quot;tsunami_1730&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="population_scenario">
      <value value="&quot;daytime&quot;"/>
      <value value="&quot;nighttime&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_route_type">
      <value value="&quot;shortest&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_willingness_prob">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="vert_evacuation_willingness_prob">
      <value value="0.75"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="confusion_ratio">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="departure_time_mean_in_sec">
      <value value="180"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="alternative_shelter_radius_meters">
      <value value="500"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="vina_del_mar_vertical75_dt480" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [moving?]</metric>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;vina_del_mar&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="tsunami_scenario">
      <value value="&quot;tsunami_1730&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="population_scenario">
      <value value="&quot;daytime&quot;"/>
      <value value="&quot;nighttime&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_route_type">
      <value value="&quot;shortest&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_willingness_prob">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="vert_evacuation_willingness_prob">
      <value value="0.75"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="confusion_ratio">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="departure_time_mean_in_sec">
      <value value="480"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="alternative_shelter_radius_meters">
      <value value="500"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="vina_del_mar_vertical75_dt660" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <metric>count pedestrians with [moving?]</metric>
    <metric>count pedestrians with [dead?]</metric>
    <metric>count pedestrians with [evacuated?]</metric>
    <enumeratedValueSet variable="data_path">
      <value value="&quot;vina_del_mar&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="tsunami_scenario">
      <value value="&quot;tsunami_1730&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="population_scenario">
      <value value="&quot;daytime&quot;"/>
      <value value="&quot;nighttime&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_route_type">
      <value value="&quot;shortest&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="flow_depth_threshold">
      <value value="0.1"/>
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="evacuation_willingness_prob">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="vert_evacuation_willingness_prob">
      <value value="0.75"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="confusion_ratio">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="departure_time_mean_in_sec">
      <value value="660"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="alternative_shelter_radius_meters">
      <value value="500"/>
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
