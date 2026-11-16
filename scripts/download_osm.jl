# Download the Oslo street network and map features from OpenStreetMap into
# data/raw/osm/ (git-ignored), through the public Overpass API.
#
#   julia --project=. scripts/download_osm.jl
#
# Data: © OpenStreetMap contributors, Open Database Licence (ODbL).

const OVERPASS = "https://overpass-api.de/api/interpreter"
# south, west, north, east: all stations plus a margin
const BOX = "59.888,10.630,59.962,10.835"

const DRIVABLE = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|" *
                 "motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"

const QUERIES = [
    "roads.json" => """
        [out:json][timeout:180];
        way["highway"~"^($DRIVABLE)\$"]($BOX);
        out geom;""",
    "features.json" => """
        [out:json][timeout:180];
        (
          way["natural"="coastline"]($BOX);
          way["natural"="water"]($BOX);
          relation["natural"="water"]($BOX);
          way["waterway"~"^(river|stream|canal)\$"]($BOX);
          way["leisure"="park"]($BOX);
          relation["leisure"="park"]($BOX);
          way["landuse"~"^(forest|cemetery|grass)\$"]($BOX);
          way["natural"="wood"]($BOX);
        );
        out geom;""",
]

function main()
    dir = joinpath(@__DIR__, "..", "data", "raw", "osm")
    mkpath(dir)
    for (name, query) in QUERIES
        target = joinpath(dir, name)
        if isfile(target)
            println("have     ", target)
            continue
        end
        # Overpass can take a minute before it sends the first byte, so use curl with a long
        # timeout; Julia's own downloader gives up on slow starts.
        try
            run(`curl --silent --show-error --fail --max-time 600 --user-agent bike-rebalancing-study/0.1
                      --data-urlencode $("data=" * query) --output $target $OVERPASS`)
        catch
            rm(target; force = true)
            rethrow()
        end
        println("fetched  ", target, "  (", round(filesize(target) / 1e6; digits = 1), " MB)")
    end
end

main()
