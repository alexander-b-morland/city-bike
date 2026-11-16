# First look at the Oslo Bysykkel data. Prints summary tables and writes per-station and
# per-hour summaries to results/exploration/.
#
#   julia --project=. scripts/download_oslo.jl 2025-11 2026-10
#   julia --project=. notebooks/explore_oslo.jl

using CSV
using DataFrames
using Dates
using JSON
using Printf
using Statistics

const ROOT = joinpath(@__DIR__, "..")
const RAW = joinpath(ROOT, "data", "raw", "oslo")
const OUT = joinpath(ROOT, "results", "exploration")

# ---------------------------------------------------------------- loading

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

parse_utc(text) = DateTime(SubString(text, 1, 19), dateformat"yyyy-mm-dd HH:MM:SS")

function load_trips()
    columns = [:started_at, :ended_at, :duration, :start_station_id, :end_station_id,
               :start_station_latitude, :start_station_longitude,
               :end_station_latitude, :end_station_longitude]
    files = sort(readdir(joinpath(RAW, "trips"); join = true))
    trips = reduce(vcat, [CSV.read(file, DataFrame; select = columns, stringtype = String)
                          for file in files])
    trips.start = oslo_time.(parse_utc.(trips.started_at))
    trips.stop = oslo_time.(parse_utc.(trips.ended_at))
    select!(trips, Not([:started_at, :ended_at]))
    rename!(trips, :start_station_id => :from, :end_station_id => :to)
    return trips
end

function load_stations()
    info = JSON.parsefile(joinpath(RAW, "gbfs", "station_information.json"))
    rows = info["data"]["stations"]
    return DataFrame(
        id = [parse(Int, row["station_id"]) for row in rows],
        name = [String(row["name"]) for row in rows],
        lat = [Float64(row["lat"]) for row in rows],
        lon = [Float64(row["lon"]) for row in rows],
        capacity = [Int(row["capacity"]) for row in rows],
    )
end

function load_status()
    files = filter(startswith("station_status_"), readdir(joinpath(RAW, "gbfs")))
    file = last(sort(files))
    rows = JSON.parsefile(joinpath(RAW, "gbfs", file))["data"]["stations"]
    count_of(row, kind) = sum((v["count"] for v in row["vehicle_types_available"]
                               if v["vehicle_type_id"] == kind); init = 0)
    status = DataFrame(
        id = [parse(Int, row["station_id"]) for row in rows],
        bikes = [Int(row["num_bikes_available"]) for row in rows],
        docks = [Int(row["num_docks_available"]) for row in rows],
        ebikes = [count_of(row, "ebike") for row in rows],
        active = [Bool(row["is_installed"]) && Bool(row["is_renting"]) for row in rows],
    )
    return status, file
end

"Great-circle distance in km."
function haversine(lat1, lon1, lat2, lon2)
    a = sind((lat2 - lat1) / 2)^2 + cosd(lat1) * cosd(lat2) * sind((lon2 - lon1) / 2)^2
    return 2 * 6371.0 * asin(sqrt(a))
end

# A "service day" runs from 04:00 to 04:00, so trips just after midnight belong to the
# evening before.
service_day(time::DateTime) = Date(time - Hour(4))
is_weekday(day::Date) = dayofweek(day) <= 5

section(title) = println("\n== ", title, " ", "="^max(0, 70 - length(title)))

# ---------------------------------------------------------------- analysis

function main()
    mkpath(OUT)
    trips = load_trips()
    stations = load_stations()
    status, status_file = load_status()

    section("Size")
    @printf("trips: %d from %s to %s\n", nrow(trips), Date(minimum(trips.start)),
            Date(maximum(trips.start)))
    @printf("stations in feed: %d, docks in total: %d (median %d per station)\n",
            nrow(stations), sum(stations.capacity), median(stations.capacity))
    used = union(trips.from, trips.to)
    @printf("stations in trips: %d, of which %d are in today's feed\n", length(used),
            length(intersect(used, stations.id)))
    known = in(Set(stations.id))
    @printf("trips between stations in today's feed: %.1f%%\n",
            100 * mean(known.(trips.from) .& known.(trips.to)))

    section("Live snapshot ($status_file)")
    live = status[status.active, :]
    @printf("active stations: %d, bikes parked: %d (%d electric), free docks: %d\n",
            nrow(live), sum(live.bikes), sum(live.ebikes), sum(live.docks))
    @printf("empty stations: %d, full stations: %d\n", count(==(0), live.bikes),
            count(==(0), live.docks))

    section("Trips per month and per day")
    trips.day = service_day.(trips.start)
    monthly = combine(groupby(transform(trips, :day => ByRow(d -> Dates.format(d, "yyyy-mm")) => :month), :month),
                      nrow => :trips, :day => (d -> length(unique(d))) => :days)
    monthly.per_day = round.(Int, monthly.trips ./ monthly.days)
    show(sort(monthly, :month); allrows = true, summary = false)
    println()

    section("Trip length")
    km = haversine.(trips.start_station_latitude, trips.start_station_longitude,
                    trips.end_station_latitude, trips.end_station_longitude)
    @printf("duration, minutes: median %.1f, 90th percentile %.1f\n",
            median(trips.duration) / 60, quantile(trips.duration, 0.9) / 60)
    @printf("straight-line distance, km: median %.2f, 90th percentile %.2f\n",
            median(km), quantile(km, 0.9))
    @printf("round trips to the same station: %.1f%%\n", 100 * mean(trips.from .== trips.to))

    # Peak season: June to September.
    season = trips[Date(2026, 6, 1) .<= trips.day .<= Date(2026, 9, 30), :]
    weekdays = season[is_weekday.(season.day), :]
    weekend = season[.!is_weekday.(season.day), :]
    n_weekdays, n_weekend = length(unique(weekdays.day)), length(unique(weekend.day))

    section("Hour of day, June to September (trips started per hour, per day)")
    hourly = DataFrame(hour = 0:23)
    hourly.weekday = [count(==(h), hour.(weekdays.start)) / n_weekdays for h in 0:23]
    hourly.weekend = [count(==(h), hour.(weekend.start)) / n_weekend for h in 0:23]
    hourly.weekday_share = round.(100 .* hourly.weekday ./ sum(hourly.weekday); digits = 1)
    hourly.weekday = round.(hourly.weekday; digits = 1)
    hourly.weekend = round.(hourly.weekend; digits = 1)
    show(hourly; allrows = true, summary = false)
    println()
    CSV.write(joinpath(OUT, "hourly.csv"), hourly)
    quiet = hourly.hour[hourly.weekday_share .< 0.5]
    println("weekday hours with under 0.5% of the day's trips: ", quiet)
    @printf("share of weekday trips started between 01:00 and 06:00: %.1f%%\n",
            sum(hourly.weekday_share[2:6]))

    section("Daily drift per station, weekdays June to September")
    # Net change over a service day from user trips alone: arrivals minus departures.
    out = combine(groupby(weekdays, [:day, :from]), nrow => :departures)
    into = combine(groupby(weekdays, [:day, :to]), nrow => :arrivals)
    rename!(out, :from => :id)
    rename!(into, :to => :id)
    flows = outerjoin(out, into; on = [:day, :id])
    flows.departures = coalesce.(flows.departures, 0)
    flows.arrivals = coalesce.(flows.arrivals, 0)
    flows.net = flows.arrivals .- flows.departures

    per_day = combine(groupby(flows, :day), :net => (n -> sum(max.(n, 0))) => :misplaced,
                      :departures => sum => :trips)
    @printf("bikes ending the day at a different station than they started, net:\n")
    @printf("  mean %.0f per weekday, 10th to 90th percentile %.0f to %.0f (of about %.0f trips)\n",
            mean(per_day.misplaced), quantile(per_day.misplaced, 0.1),
            quantile(per_day.misplaced, 0.9), mean(per_day.trips))

    drift = combine(groupby(flows, :id), :net => (n -> sum(n) / n_weekdays) => :drift,
                    :net => (n -> std(vcat(n, zeros(n_weekdays - length(n))))) => :drift_sd,
                    :departures => (d -> sum(d) / n_weekdays) => :departures,
                    :arrivals => (a -> sum(a) / n_weekdays) => :arrivals)
    @printf("systematic part (each station's average): %.0f bikes per weekday\n",
            sum(max.(drift.drift, 0)))
    sized = innerjoin(drift, stations; on = :id)
    @printf("stations whose average gain or loss is more than half their docks: %d of %d\n",
            count(abs.(sized.drift) .> sized.capacity ./ 2), nrow(stations))
    @printf("stations that gain more bikes on an average weekday than they have docks: %d\n",
            count(sized.drift .> sized.capacity))

    section("Morning rush per station, weekdays 06:00 to 10:00")
    # Walk through the morning's events at each station. The lowest point of the running
    # balance is how many bikes the station must hold at 06:00 to serve every departure;
    # the highest point is how many free docks it needs.
    in_morning(time) = 6 <= hour(time) < 10
    leaving = weekdays[in_morning.(weekdays.start), [:day, :from, :start]]
    arriving = weekdays[in_morning.(weekdays.stop), [:day, :to, :stop]]
    events = vcat(DataFrame(day = leaving.day, id = leaving.from, time = leaving.start, change = -1),
                  DataFrame(day = Date.(arriving.stop), id = arriving.to, time = arriving.stop, change = 1))
    sort!(events, [:id, :day, :time])
    needs = combine(groupby(events, [:id, :day])) do group
        balance = cumsum(group.change)
        (bikes_needed = max(0, -minimum(balance)), docks_needed = max(0, maximum(balance)))
    end
    padded(values) = vcat(values, zeros(n_weekdays - length(values)))
    morning = combine(groupby(needs, :id),
                      :bikes_needed => (v -> mean(padded(v))) => :bikes_mean,
                      :bikes_needed => (v -> quantile(padded(v), 0.9)) => :bikes_p90,
                      :docks_needed => (v -> mean(padded(v))) => :docks_mean,
                      :docks_needed => (v -> quantile(padded(v), 0.9)) => :docks_p90)

    table = leftjoin(stations, drift; on = :id)
    table = leftjoin(table, morning; on = :id)
    table = leftjoin(table, status[:, [:id, :bikes, :docks, :ebikes]]; on = :id)
    for column in names(table, Not([:id, :name]))
        table[!, column] = coalesce.(table[!, column], 0)
    end
    table.window = table.capacity .- table.docks_p90 .- table.bikes_p90
    sort!(table, :drift)
    CSV.write(joinpath(OUT, "stations.csv"), table)

    @printf("bikes needed at 06:00 across all stations: %.0f on average, %.0f to cover 9 days in 10\n",
            sum(table.bikes_mean), sum(table.bikes_p90))
    @printf("free docks needed at 06:00: %.0f on average, %.0f to cover 9 days in 10\n",
            sum(table.docks_mean), sum(table.docks_p90))
    @printf("stations where the 9-in-10 bike need plus dock need exceeds capacity: %d\n",
            count(<(0), table.window))

    shown = [:name, :capacity, :drift, :drift_sd, :departures, :arrivals, :bikes_p90, :docks_p90]
    rounded = transform(table[:, shown], names(table[:, shown], Float64) .=> ByRow(x -> round(x; digits = 1)); renamecols = false)
    println("\nstations that lose the most bikes over a weekday:")
    show(first(rounded, 12); allrows = true, summary = false, truncate = 40)
    println("\n\nstations that gain the most bikes over a weekday:")
    show(last(rounded, 12); allrows = true, summary = false, truncate = 40)
    println()

    println("\nwrote ", OUT)
end

main()
