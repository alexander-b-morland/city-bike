# Turn the OpenStreetMap downloads into a small base map for the result pages:
# streets, parks, lakes, the river and the fjord.
#
#   julia --project=. scripts/download_osm.jl
#   julia --project=. scripts/build_map.jl
#
# Writes report/map/oslo.js. Map data © OpenStreetMap contributors, ODbL.

using CityBike: thin_line
using JSON

const ROOT = joinpath(@__DIR__, "..")
const SOUTH, WEST, NORTH, EAST = 59.892, 10.640, 59.958, 10.825
const UNIT = 1e-5                       # coordinates are stored in steps of this many degrees
const SEA_COLUMNS, SEA_ROWS = 1400, 1000
const SEA_SEEDS = [(59.9012, 10.722), (59.8935, 10.700), (59.8935, 10.745)]   # points in the fjord

Point = Tuple{Float64,Float64}
points(way) = Point[(p["lat"], p["lon"]) for p in way["geometry"]]
inside(line) = any(SOUTH <= lat <= NORTH && WEST <= lon <= EAST for (lat, lon) in line)
closed(line) = length(line) >= 4 && line[1] == line[end]

"A line as whole numbers: the first point, then the step to each next point."
function encode(line::Vector{Point}, tolerance)
    line = thin_line(line, tolerance)
    xs = [round(Int, (lon - WEST) / UNIT) for (_, lon) in line]
    ys = [round(Int, (lat - SOUTH) / UNIT) for (lat, _) in line]
    numbers = [xs[1], ys[1]]
    for k in 2:length(line)
        push!(numbers, xs[k] - xs[k - 1], ys[k] - ys[k - 1])
    end
    return numbers
end

"Outlines of an element: the way itself, or the closed outer rings of a relation."
function outlines(element)
    element["type"] == "way" && return [points(element)]
    return [points(member) for member in element["members"]
            if member["type"] == "way" && get(member, "role", "") == "outer" && haskey(member, "geometry")]
end

"Metres squared inside a closed line, to drop slivers."
function area(line)
    scale = 111_320.0
    total = 0.0
    for k in 1:length(line) - 1
        (y1, x1), (y2, x2) = line[k], line[k + 1]
        total += (x1 * y2 - x2 * y1)
    end
    return abs(total) / 2 * scale^2 * cosd(SOUTH)
end

"""
The fjord as runs of water cells per row. The coastline is drawn onto a grid and the
water is flooded from points known to be in the fjord, which avoids stitching the
coastline into polygons.
"""
function sea_runs(coast::Vector{Vector{Point}})
    wall = falses(SEA_ROWS, SEA_COLUMNS)
    cell(lat, lon) = (clamp(floor(Int, (NORTH - lat) / (NORTH - SOUTH) * SEA_ROWS) + 1, 1, SEA_ROWS),
                      clamp(floor(Int, (lon - WEST) / (EAST - WEST) * SEA_COLUMNS) + 1, 1, SEA_COLUMNS))
    for line in coast, k in 1:length(line) - 1
        (lat1, lon1), (lat2, lon2) = line[k], line[k + 1]
        # Skip pieces that lie wholly outside the map, so clamping does not smear them along the edge.
        (max(lat1, lat2) < SOUTH || min(lat1, lat2) > NORTH || max(lon1, lon2) < WEST || min(lon1, lon2) > EAST) && continue
        steps = 2 * (1 + ceil(Int, max(abs(lat2 - lat1) / (NORTH - SOUTH) * SEA_ROWS, abs(lon2 - lon1) / (EAST - WEST) * SEA_COLUMNS)))
        for step in 0:steps
            t = step / steps
            row, column = cell(lat1 + t * (lat2 - lat1), lon1 + t * (lon2 - lon1))
            wall[row, column] = true
            # Thicken the wall so the flood cannot slip through a diagonal.
            row < SEA_ROWS && (wall[row + 1, column] = true)
            column < SEA_COLUMNS && (wall[row, column + 1] = true)
        end
    end
    water = falses(SEA_ROWS, SEA_COLUMNS)
    stack = [cell(lat, lon) for (lat, lon) in SEA_SEEDS]
    while !isempty(stack)
        row, column = pop!(stack)
        (1 <= row <= SEA_ROWS && 1 <= column <= SEA_COLUMNS) || continue
        (water[row, column] || wall[row, column]) && continue
        water[row, column] = true
        push!(stack, (row + 1, column), (row - 1, column), (row, column + 1), (row, column - 1))
    end
    share = count(water) / length(water)
    0.03 < share < 0.35 || error("the fjord covers $(round(100 * share))% of the map; the flood must have leaked")
    rows = Vector{Int}[]
    for row in 1:SEA_ROWS
        runs, column = Int[], 1
        while column <= SEA_COLUMNS
            if water[row, column] || (wall[row, column] && column > 1 && water[row, column - 1])
                start = column
                while column <= SEA_COLUMNS && (water[row, column] || wall[row, column])
                    column += 1
                end
                push!(runs, start - 1, column - start)
            else
                column += 1
            end
        end
        push!(rows, runs)
    end
    return rows, share
end

function main()
    roads = Dict(name => Vector{Int}[] for name in ("major", "medium", "minor", "tunnel"))
    group = Dict("motorway" => "major", "trunk" => "major", "primary" => "major",
                 "secondary" => "medium", "tertiary" => "medium")
    for way in JSON.parsefile(joinpath(ROOT, "data", "raw", "osm", "roads.json"))["elements"]
        line = points(way)
        inside(line) || continue
        tags = way["tags"]
        class = replace(tags["highway"], "_link" => "")
        name = get(tags, "tunnel", "no") != "no" ? "tunnel" : get(group, class, "minor")
        push!(roads[name], encode(line, 2.0))
    end

    parks, lakes, rivers, coast = Vector{Int}[], Vector{Int}[], Vector{Int}[], Vector{Point}[]
    for element in JSON.parsefile(joinpath(ROOT, "data", "raw", "osm", "features.json"))["elements"]
        tags = get(element, "tags", Dict())
        natural, leisure, landuse, waterway = (get(tags, key, "") for key in ("natural", "leisure", "landuse", "waterway"))
        for line in outlines(element)
            inside(line) || continue
            if natural == "coastline"
                push!(coast, line)
            elseif waterway == "river"
                push!(rivers, encode(line, 3.0))
            elseif natural == "water"
                closed(line) && area(line) > 400 && push!(lakes, encode(line, 2.0))
            elseif leisure == "park" || natural == "wood" || landuse in ("forest", "cemetery")
                closed(line) && area(line) > 2500 && push!(parks, encode(line, 4.0))
            end
        end
    end
    rows, share = sea_runs(coast)

    map = Dict("box" => [SOUTH, WEST, NORTH, EAST], "unit" => UNIT, "roads" => roads, "parks" => parks,
               "lakes" => lakes, "rivers" => rivers, "coast" => [encode(line, 2.0) for line in coast],
               "sea" => Dict("columns" => SEA_COLUMNS, "rows" => rows))
    target = joinpath(ROOT, "report", "map")
    mkpath(target)
    file = joinpath(target, "oslo.js")
    open(file, "w") do io
        print(io, "// Map data © OpenStreetMap contributors, Open Database Licence.\nwindow.OSLO_MAP = ")
        JSON.print(io, map)
        println(io, ";")
    end
    println("streets: ", sum(length, values(roads)), ", parks: ", length(parks), ", lakes: ", length(lakes),
            ", fjord: ", round(100 * share; digits = 1), "% of the map, file: ", round(filesize(file) / 1e6; digits = 2), " MB")
end

main()
