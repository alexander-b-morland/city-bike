# Driving times and distances, either along real streets or as the crow flies.

"Travel as in the first model: straight lines stretched by the truck's detour factor."
function straight_line_travel(truck::Truck, stations::Vector{Station})
    lat = [[station.lat for station in stations]; truck.depot_lat]
    lon = [[station.lon for station in stations]; truck.depot_lon]
    km = [truck.detour * haversine(lat[a], lon[a], lat[b], lon[b]) for a in eachindex(lat), b in eachindex(lat)]
    return Travel(60 .* km ./ truck.speed_kmh, km)
end

"The street network, with the fastest routes from every place to everywhere."
struct Roads
    lat::Vector{Float64}                 # network nodes
    lon::Vector{Float64}
    ways::Vector{Tuple{String,Vector{Int}}}   # road class and node sequence, for drawing
    node::Vector{Int}                    # network node of each place
    previous::Matrix{Int32}              # previous[node, place]: node before it on the route from place
    travel::Travel
end

# Speed limit assumed where the map has none, by road class (km/h).
const DEFAULT_LIMIT = Dict("motorway" => 80, "trunk" => 60, "primary" => 50, "secondary" => 40, "tertiary" => 40,
                           "unclassified" => 30, "residential" => 30, "living_street" => 10)
# A truck averages this share of the speed limit once turns, lights and crossings are counted.
const SPEED_SHARE = 0.7

function limit_of(tags)
    limit = tryparse(Float64, get(tags, "maxspeed", ""))
    limit === nothing || return limit
    return Float64(get(DEFAULT_LIMIT, replace(tags["highway"], "_link" => ""), 30))
end

"Nodes that can be reached from `origin` following `links`."
function reachable(links::Vector{Vector{Tuple{Int,Float64,Float64}}}, origin::Int)
    seen = falses(length(links))
    seen[origin] = true
    stack = [origin]
    while !isempty(stack)
        for (next, _, _) in links[pop!(stack)]
            seen[next] || (seen[next] = true; push!(stack, next))
        end
    end
    return seen
end

"""
Read an Overpass export of drivable ways and work out the fastest route between every
pair of places (the stations, then the truck's depot). One-way streets are respected;
private and closed roads are left out. Each place is attached to the nearest street node.
"""
function load_roads(file::AbstractString, stations::Vector{Station}, truck::Truck)
    index = Dict{Int,Int}()
    lat, lon = Float64[], Float64[]
    ways = Tuple{String,Vector{Int}}[]
    out = Vector{Tuple{Int,Float64,Float64}}[]    # per node: (next node, minutes, km)
    back = Vector{Tuple{Int,Float64,Float64}}[]
    for way in JSON.parsefile(file)["elements"]
        tags = way["tags"]
        (get(tags, "access", "") in ("no", "private") || get(tags, "motor_vehicle", "") in ("no", "private")) && continue
        nodes = Int[]
        for (id, point) in zip(way["nodes"], way["geometry"])
            push!(nodes, get!(index, id) do
                push!(lat, point["lat"]); push!(lon, point["lon"]); push!(out, []); push!(back, [])
                length(lat)
            end)
        end
        push!(ways, (replace(tags["highway"], "_link" => ""), nodes))
        speed = SPEED_SHARE * limit_of(tags)
        direction = get(tags, "oneway", "no")
        forward = direction != "-1"
        backward = direction == "-1" || !(direction == "yes" || get(tags, "junction", "") in ("roundabout", "circular"))
        for (a, b) in zip(nodes, nodes[2:end])
            km = haversine(lat[a], lon[a], lat[b], lon[b])
            minutes = 60 * km / speed
            forward && (push!(out[a], (b, minutes, km)); push!(back[b], (a, minutes, km)))
            backward && (push!(out[b], (a, minutes, km)); push!(back[a], (b, minutes, km)))
        end
    end

    # Keep to the part of the network a truck can both reach from the depot and return from.
    nearest(place_lat, place_lon, allowed) =
        argmin(n -> allowed[n] ? haversine(place_lat, place_lon, lat[n], lon[n]) : Inf, eachindex(lat))
    home = nearest(truck.depot_lat, truck.depot_lon, trues(length(lat)))
    connected = reachable(out, home) .& reachable(back, home)
    places = [[(station.lat, station.lon) for station in stations]; (truck.depot_lat, truck.depot_lon)]
    node = [nearest(place_lat, place_lon, connected) for (place_lat, place_lon) in places]

    n, m = length(lat), length(places)
    previous = zeros(Int32, n, m)
    minutes, km = zeros(m, m), zeros(m, m)
    for (place, origin) in enumerate(node)
        time, distance = fill(Inf, n), zeros(n)
        time[origin] = 0.0
        queue = BinaryMinHeap{Tuple{Float64,Int}}()
        push!(queue, (0.0, origin))
        while !isempty(queue)
            reached, a = pop!(queue)
            reached > time[a] && continue
            for (b, step_minutes, step_km) in out[a]
                if reached + step_minutes < time[b]
                    time[b] = reached + step_minutes
                    distance[b] = distance[a] + step_km
                    previous[b, place] = a
                    push!(queue, (time[b], b))
                end
            end
        end
        minutes[place, :] = time[node]
        km[place, :] = distance[node]
    end
    all(isfinite, minutes) || error("some places cannot be reached by road")
    return Roads(lat, lon, ways, node, previous, Travel(minutes, km))
end

"The fastest route from place `a` to place `b`, as a list of (lat, lon) points."
function route(roads::Roads, a::Int, b::Int)
    points, at = Tuple{Float64,Float64}[], roads.node[b]
    while at != roads.node[a]
        push!(points, (roads.lat[at], roads.lon[at]))
        at = roads.previous[at, a]
    end
    push!(points, (roads.lat[at], roads.lon[at]))
    return reverse!(points)
end

"""
Drop points from a line of (lat, lon) points wherever the line stays within
`tolerance_m` metres of the original (Douglas-Peucker).
"""
function thin_line(points::Vector{Tuple{Float64,Float64}}, tolerance_m::Real)
    length(points) <= 2 && return points
    scale = cosd(points[1][1])
    metres(p) = (111_320 * p[1], 111_320 * scale * p[2])
    keep = falses(length(points))
    keep[1] = keep[end] = true
    stack = [(1, length(points))]
    while !isempty(stack)
        first, last = pop!(stack)
        (ay, ax), (by, bx) = metres(points[first]), metres(points[last])
        span = hypot(by - ay, bx - ax)
        worst, far = 0.0, 0
        for k in first + 1:last - 1
            py, px = metres(points[k])
            offset = span == 0 ? hypot(py - ay, px - ax) : abs((bx - ax) * (ay - py) - (ax - px) * (by - ay)) / span
            offset > worst && ((worst, far) = (offset, k))
        end
        if worst > tolerance_m
            keep[far] = true
            push!(stack, (first, far), (far, last))
        end
    end
    return points[keep]
end
