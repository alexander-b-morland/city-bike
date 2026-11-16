# Loading Oslo Bysykkel stations and trips.

struct Station
    id::Int
    name::String
    lat::Float64
    lon::Float64
    capacity::Int
end

"One ride between two stations, given as positions in the station list, in Oslo time."
struct Trip
    from::Int
    to::Int
    start::DateTime
    stop::DateTime
end

"Last Sunday of the given month at 01:00 UTC, when European clocks change."
function clock_change(year, month)
    day = lastdayofmonth(Date(year, month))
    while dayofweek(day) != Dates.Sunday
        day -= Day(1)
    end
    return DateTime(day) + Hour(1)
end

"Convert a UTC time to Oslo wall-clock time."
function oslo_time(utc::DateTime)
    summer = clock_change(year(utc), 3) <= utc < clock_change(year(utc), 10)
    return utc + Hour(summer ? 2 : 1)
end

"Parse a timestamp such as `2026-05-31 22:00:15.503000+00:00`, dropping the fraction."
parse_utc(text) = DateTime(SubString(text, 1, 19), dateformat"yyyy-mm-dd HH:MM:SS")

"Great-circle distance in km."
function haversine(lat1, lon1, lat2, lon2)
    a = sind((lat2 - lat1) / 2)^2 + cosd(lat1) * cosd(lat2) * sind((lon2 - lon1) / 2)^2
    return 2 * 6371.0 * asin(sqrt(a))
end

haversine(a::Station, b::Station) = haversine(a.lat, a.lon, b.lat, b.lon)

# A service day runs from 01:00 to 01:00. The truck works at the start of it.
const DAY_START = Hour(1)
service_day(time::DateTime) = Date(time - DAY_START)
is_weekday(day::Date) = dayofweek(day) <= 5

"Stations from the GBFS `station_information.json` feed, sorted by id."
function load_stations(file::AbstractString)
    rows = JSON.parsefile(file)["data"]["stations"]
    stations = [Station(parse(Int, row["station_id"]), String(row["name"]), Float64(row["lat"]),
                        Float64(row["lon"]), Int(row["capacity"])) for row in rows]
    return sort!(stations; by = station -> station.id)
end

"""
Trips from the monthly files in `dir` whose service day lies in `first:last`, sorted by
start time. Trips to or from a station that is not in `stations` are dropped.
"""
function load_trips(dir::AbstractString, stations::Vector{Station}, first::Date, last::Date)
    position = Dict(station.id => index for (index, station) in enumerate(stations))
    columns = [:started_at, :ended_at, :start_station_id, :end_station_id]
    trips = Trip[]
    # A trip that starts just after midnight is filed under the next calendar month.
    for month in floor(first, Month):Month(1):floor(last + Day(1), Month)
        file = joinpath(dir, Dates.format(month, "yyyy-mm") * ".csv")
        isfile(file) || error("missing trip file $file; run scripts/download_oslo.jl")
        for row in CSV.File(file; select = columns, stringtype = String)
            from = get(position, row.start_station_id, 0)
            to = get(position, row.end_station_id, 0)
            (from == 0 || to == 0) && continue
            start = oslo_time(parse_utc(row.started_at))
            first <= service_day(start) <= last || continue
            push!(trips, Trip(from, to, start, oslo_time(parse_utc(row.ended_at))))
        end
    end
    return sort!(trips; by = trip -> trip.start)
end
