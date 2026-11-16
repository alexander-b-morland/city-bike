# Download Oslo Bysykkel open data into data/raw/oslo/ (git-ignored).
#
#   julia --project=. scripts/download_oslo.jl 2025-11 2026-10
#
# Fetches one trip file per month in the given range, plus a snapshot of the station
# feeds (locations, capacities, vehicle types and current bike counts). Trip files
# already on disk are skipped. The live station status is saved under a timestamped
# name, so running the script again adds a new snapshot.
#
# Data: Oslo Bysykkel, Norwegian Licence for Open Government Data (NLOD) 2.0.

using Dates
using Downloads

const TRIPS_URL = "https://data.urbansharing.com/oslobysykkel.no/trips/v1"
const GBFS_URL = "https://gbfs.urbansharing.com/oslobysykkel.no"
# The feeds ask every client to identify itself as "<organisation>-<application>".
const CLIENT_ID = get(ENV, "BYSYKKEL_CLIENT_ID", "personal-rebalancing-study")

function months_between(first::AbstractString, last::AbstractString)
    from, to = Date(first, dateformat"yyyy-mm"), Date(last, dateformat"yyyy-mm")
    from <= to || error("first month $first is after last month $last")
    return from:Month(1):to
end

function download_trips(months, dir)
    mkpath(dir)
    for month in months
        target = joinpath(dir, Dates.format(month, "yyyy-mm") * ".csv")
        if isfile(target)
            println("have     ", target)
            continue
        end
        url = "$TRIPS_URL/$(Dates.format(month, "yyyy/mm")).csv"
        Downloads.download(url, target)
        println("fetched  ", target, "  (", round(filesize(target) / 1e6; digits = 1), " MB)")
    end
end

function download_station_feeds(dir)
    mkpath(dir)
    headers = ["Client-Identifier" => CLIENT_ID]
    stamp = Dates.format(now(UTC), "yyyymmddTHHMMSS") * "Z"
    for (feed, name) in [
        "station_information" => "station_information.json",
        "vehicle_types" => "vehicle_types.json",
        "station_status" => "station_status_$stamp.json",
    ]
        target = joinpath(dir, name)
        Downloads.download("$GBFS_URL/$feed.json", target; headers)
        println("fetched  ", target)
    end
end

function main(args)
    length(args) == 2 || error("usage: download_oslo.jl <first yyyy-mm> <last yyyy-mm>")
    root = joinpath(@__DIR__, "..", "data", "raw", "oslo")
    download_trips(months_between(args[1], args[2]), joinpath(root, "trips"))
    download_station_feeds(joinpath(root, "gbfs"))
end

main(ARGS)
