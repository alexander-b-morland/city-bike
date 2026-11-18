# Draw the figures for the written report from the experiment results, as SVG files in
# report/figures/, and collect the key numbers in report/figures/numbers.json.
#
#   julia --project=. scripts/figures.jl

using CityBike
using Dates
using JSON
using Printf

const ROOT = joinpath(@__DIR__, "..")
const OUT = joinpath(ROOT, "report", "figures")
# A plain two-tone look: navy for what the figure is about, grey for what it is compared
# with. Thin lines, square bars, no decoration.
const INK, SOFT, MUTED, GRID = "#1a1a1a", "#444444", "#6f6f6f", "#e6e6e6"
const NAVY, GRAY, LIGHT = "#1f3a5f", "#8a8a8a", "#c4c4c4"
const BRICK, STEEL = "#b5473c", "#2f6399"
const FONT = "font-family=\"Helvetica Neue, Helvetica, Arial, sans-serif\""

nice_top(v) = (step = 10.0^floor(log10(v)); first(m * step for m in (1, 2, 2.5, 5, 10) if m * step >= v))
label(v) = v == round(v) ? string(round(Int, v)) : string(round(v; digits = 1))
px(v) = round(v; digits = 1)

"Start an SVG with a white background, the y-axis label, hairline gridlines and a baseline."
function frame(io, width, height, left, right, top, bottom, ytop; title, ylabel, suffix = "")
    println(io, """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $width $height" width="$width" height="$height" $FONT font-size="12">""")
    println(io, """<title>$title</title><rect width="$width" height="$height" fill="#ffffff"/>""")
    println(io, """<text x="$left" y="$(top - 12)" fill="$MUTED">$ylabel</text>""")
    y(v) = top + (height - top - bottom) * (1 - v / ytop)
    for k in 0:5
        v = ytop * k / 5
        k == 0 || println(io, """<line x1="$left" x2="$(width - right)" y1="$(px(y(v)))" y2="$(px(y(v)))" stroke="$GRID" stroke-width="0.75"/>""")
        println(io, """<text x="$(left - 8)" y="$(px(y(v) + 4))" text-anchor="end" fill="$MUTED">$(label(v))$suffix</text>""")
    end
    println(io, """<line x1="$left" x2="$(width - right)" y1="$(px(y(0)))" y2="$(px(y(0)))" stroke="$INK" stroke-width="1"/>""")
    return y
end

"""
A line chart. `series` is a list of (name, colour, xs, ys, dashed). Each line is named
at its right end, in its own colour. `xticks` is a list of (x, text). The title is kept
as the figure's accessible name; captions belong in the text around the figure.
"""
function line_chart(file; title, ylabel, xlabel, series, xticks, suffix = "", ytop = nothing, width = 720, height = 340, markers = true)
    left, right, top, bottom = 48, 132, 34, 46
    ytop = something(ytop, nice_top(maximum(maximum(s[4]) for s in series)))
    xmin, xmax = minimum(minimum(s[3]) for s in series), maximum(maximum(s[3]) for s in series)
    x(v) = left + (width - left - right) * (v - xmin) / (xmax - xmin)
    open(joinpath(OUT, file), "w") do io
        y = frame(io, width, height, left, right, top, bottom, ytop; title, ylabel, suffix)
        for (at, text) in xticks
            println(io, """<line x1="$(px(x(at)))" x2="$(px(x(at)))" y1="$(px(y(0)))" y2="$(px(y(0) + 4))" stroke="$INK" stroke-width="1"/>""")
            println(io, """<text x="$(px(x(at)))" y="$(px(y(0) + 18))" text-anchor="middle" fill="$MUTED">$text</text>""")
        end
        isempty(xlabel) || println(io, """<text x="$((left + width - right) / 2)" y="$(height - 6)" text-anchor="middle" fill="$MUTED">$xlabel</text>""")
        ends = Tuple{Float64,String,String}[]
        for (name, colour, xs, ys, dashed) in series
            points = join(("$(px(x(a))),$(px(y(b)))" for (a, b) in zip(xs, ys)), " ")
            println(io, """<polyline points="$points" fill="none" stroke="$colour" stroke-width="$(dashed ? 1.2 : 1.6)" stroke-linejoin="round" $(dashed ? "stroke-dasharray=\"4 3\"" : "")/>""")
            if markers && !dashed
                for (a, b) in zip(xs, ys)
                    println(io, """<circle cx="$(px(x(a)))" cy="$(px(y(b)))" r="2.4" fill="$colour"/>""")
                end
            end
            push!(ends, (y(ys[end]), name, colour))
        end
        sort!(ends)
        for k in 2:length(ends)
            ends[k] = (max(ends[k][1], ends[k - 1][1] + 14), ends[k][2], ends[k][3])
        end
        for (at, name, colour) in ends
            println(io, """<text x="$(width - right + 8)" y="$(px(at + 4))" fill="$colour">$name</text>""")
        end
        println(io, "</svg>")
    end
end

"A bar chart with square bars, one per label, and the value written above each bar."
function bar_chart(file; title, ylabel, xlabel = "", labels, values, colours, suffix = "", ytop = nothing, width = 720, height = 330, notes = nothing)
    left, right, top, bottom = 48, 12, 34, 58
    ytop = something(ytop, nice_top(maximum(values)))
    band = (width - left - right) / length(values)
    open(joinpath(OUT, file), "w") do io
        y = frame(io, width, height, left, right, top, bottom, ytop; title, ylabel, suffix)
        for (k, (text, value, colour)) in enumerate(zip(labels, values, colours))
            centre, bar = left + band * (k - 0.5), min(30, band * 0.58)
            println(io, """<rect x="$(px(centre - bar / 2))" y="$(px(y(value)))" width="$(px(bar))" height="$(px(y(0) - y(value)))" fill="$colour"/>""")
            note = notes === nothing ? label(value) * suffix : notes[k]
            isempty(note) || println(io, """<text x="$(px(centre))" y="$(px(y(value) - 5))" text-anchor="middle" font-size="11.5" fill="$INK">$note</text>""")
            for (row, part) in enumerate(split(text, "\n"))
                println(io, """<text x="$(px(centre))" y="$(px(y(0) + 3 + 14 * row))" text-anchor="middle" fill="$MUTED">$part</text>""")
            end
        end
        isempty(xlabel) || println(io, """<text x="$((left + width - right) / 2)" y="$(height - 6)" text-anchor="middle" fill="$MUTED">$xlabel</text>""")
        println(io, "</svg>")
    end
end

read_runs(dir) = [JSON.parsefile(joinpath(ROOT, "results", dir, file)) for file in readdir(joinpath(ROOT, "results", dir)) if endswith(file, ".json")]
trips(run) = sum(day["trips"] for day in run["days"])
down(run) = sum(day["noBike"] + day["noDock"] for day in run["days"])
share(run) = 100 * down(run) / trips(run)
per_day(run) = down(run) / length(run["days"])
km_per_night(run) = sum(sum((truck["km"] for truck in day["trucks"]); init = 0.0) for day in run["days"]) / length(run["days"])
daily_share(run) = [100 * (day["noBike"] + day["noDock"]) / day["trips"] for day in run["days"]]
moved_per_night(run) = sum(sum((sum((max(stop[2], 0) for stop in truck["stops"]); init = 0) for truck in day["trucks"]); init = 0) for day in run["days"]) / length(run["days"])

"Decode a base-map line into (x, y) pairs in map units."
function unpack(numbers)
    points, x, y = Tuple{Int,Int}[], 0, 0
    for k in 1:2:length(numbers)
        x, y = x + numbers[k], y + numbers[k + 1]
        push!(points, (x, y))
    end
    return points
end

"""
The stations on the real map, coloured by how many bikes they gain or lose over an
average summer weekday (from notebooks/explore_oslo.jl).
"""
function drift_map(file)
    text = read(joinpath(ROOT, "report", "map", "oslo.js"), String)
    map = JSON.parse(text[findfirst('{', text):findlast('}', text)])
    south, west, north, east = map["box"]
    unit = map["unit"]
    view = (59.8945, 10.6440, 59.9560, 10.8210)
    width = 900
    scale = width / ((view[4] - view[2]) * cosd(59.92))
    height = round(Int, (view[3] - view[1]) * scale)
    px(lat, lon) = (round((lon - view[2]) * cosd(59.92) * scale; digits = 1), round(height - (lat - view[1]) * scale; digits = 1))
    path(numbers; close = false) = "M" * join(("$(p[1]) $(p[2])" for p in (px(south + y * unit, west + x * unit) for (x, y) in unpack(numbers))), "L") * (close ? "Z" : "")
    stations = [split(line, ",") for line in readlines(joinpath(ROOT, "results", "exploration", "stations.csv"))[2:end]]
    open(joinpath(OUT, file), "w") do io
        println(io, """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $width $(height + 62)" width="$width" height="$(height + 62)" $FONT font-size="12">""")
        println(io, """<rect width="$width" height="$(height + 62)" fill="#ffffff"/><clipPath id="c"><rect width="$width" height="$height"/></clipPath><g clip-path="url(#c)">""")
        println(io, """<rect width="$width" height="$height" fill="#f5f5f3"/>""")
        println(io, """<path d="$(join((path(line; close = true) for line in map["parks"]), ""))" fill="#e4eadc"/>""")
        rows = map["sea"]["rows"]
        d_lat, d_lon = (north - south) / length(rows), (east - west) / map["sea"]["columns"]
        sea = IOBuffer()
        for (r, runs) in enumerate(rows), k in 1:2:length(runs)
            (x1, y1), (x2, y2) = px(north - (r - 1) * d_lat, west + runs[k] * d_lon), px(north - r * d_lat, west + (runs[k] + runs[k + 1]) * d_lon)
            (y2 < 0 || y1 > height || x2 < 0 || x1 > width) && continue
            print(sea, "M$x1 $(y1)H$(x2 + 0.5)V$(y2 + 0.5)H$(x1)Z")
        end
        println(io, """<path d="$(String(take!(sea)))" fill="#d3dfea"/>""")
        println(io, """<path d="$(join((path(line; close = true) for line in map["lakes"]), ""))" fill="#d3dfea"/>""")
        for (name, stroke) in (("medium", 1.6), ("major", 2.6))
            println(io, """<path d="$(join((path(line) for line in map["roads"][name]), ""))" fill="none" stroke="#ffffff" stroke-width="$stroke" stroke-linecap="round" stroke-linejoin="round"/>""")
        end
        for row in sort(stations; by = row -> -abs(parse(Float64, row[6])))
            lat, lon, drift = parse(Float64, row[3]), parse(Float64, row[4]), parse(Float64, row[6])
            x, y = px(lat, lon)
            colour = abs(drift) < 2 ? "#9a9a9a" : drift < 0 ? BRICK : STEEL
            println(io, """<circle cx="$x" cy="$y" r="$(round(2.5 + 1.7 * sqrt(abs(drift)); digits = 1))" fill="$colour" fill-opacity="0.9" stroke="#ffffff" stroke-width="0.6"/>""")
        end
        for (text, lat, lon) in (("Oslofjord", 59.9005, 10.722), ("Nydalen", 59.9535, 10.7665), ("Majorstuen", 59.9305, 10.706), ("Bygdøy", 59.906, 10.682), ("Blindern", 59.9445, 10.7215))
            x, y = px(lat, lon)
            println(io, """<text x="$x" y="$y" text-anchor="middle" fill="$SOFT" stroke="#f5f5f3" stroke-width="3" paint-order="stroke">$text</text>""")
        end
        println(io, "</g>")
        for (k, (colour, text)) in enumerate(((BRICK, "Loses bikes over a weekday"), (STEEL, "Gains bikes over a weekday"), ("#9a9a9a", "Within 2 bikes of balance")))
            println(io, """<circle cx="$(20 + 230 * (k - 1))" cy="$(height + 22)" r="6" fill="$colour"/><text x="$(32 + 230 * (k - 1))" y="$(height + 27)" fill="$SOFT">$text</text>""")
        end
        println(io, """<text x="14" y="$(height + 50)" fill="$MUTED">Larger circle = larger change. Map © OpenStreetMap contributors.</text></svg>""")
    end
end

function main()
    mkpath(OUT)
    numbers = Dict{String,Any}()
    fleet = read_runs("fleet_size")
    by(policy) = sort([run for run in fleet if run["policy"] == policy]; by = run -> run["trucks"])
    none = only(by("none"))
    optimal, greedy, oracle = vcat([none], by("optimal")), vcat([none], by("greedy")), by("oracle")
    count_of(run) = run["trucks"]

    # 1. Riders let down against the number of trucks.
    series = Any[("Rule of thumb", GRAY, count_of.(greedy), share.(greedy), false),
                 ("Optimized", NAVY, count_of.(optimal), share.(optimal), false)]
    isempty(oracle) || push!(series, ("Knowing tomorrow", NAVY, vcat(0, count_of.(oracle)), vcat(share(none), share.(oracle)), true))
    line_chart("fleet_size.svg"; title = "The first five trucks do almost all the work", ylabel = "Riders let down over four weeks",
               xlabel = "Trucks working each night", series, suffix = "%",
               xticks = [(k, string(k)) for k in 0:2:maximum(count_of.(greedy))])
    numbers["fleet"] = Dict(policy => [Dict("trucks" => count_of(run), "share" => round(share(run); digits = 1), "perDay" => round(per_day(run)),
                                              "kmPerNight" => round(km_per_night(run); digits = 1), "movedPerNight" => round(moved_per_night(run)))
                                         for run in runs] for (policy, runs) in (("optimal", optimal), ("greedy", greedy), ("oracle", oracle)))
    numbers["solver"] = Dict("maxGap" => maximum(day["gap"] for run in by("optimal") for day in run["days"]),
                             "secondsPerNightPerTruck" => round(sum(day["seconds"] for run in by("optimal") for day in run["days"]) /
                                                                sum(count_of(run) * length(run["days"]) for run in by("optimal")); digits = 1))

    # 2. Day by day for a few fleet sizes.
    days = Date.(String[day["day"] for day in none["days"]])
    shown = [run for run in optimal if count_of(run) in (0, 1, 4, 8)]
    shades = Dict(0 => GRAY, 1 => "#a9bdd3", 4 => "#5f82a8", 8 => NAVY)
    line_chart("four_weeks.svg"; title = "Day by day: more trucks keep the share lower and steadier", ylabel = "Riders let down each day", xlabel = "",
               series = [(count_of(run) == 0 ? "No trucks" : "$(count_of(run)) optimized truck$(count_of(run) == 1 ? "" : "s")",
                          shades[count_of(run)], collect(1:length(days)), daily_share(run), false) for run in shown],
               suffix = "%", markers = false, xticks = [(k, Dates.format(days[k], "d u")) for k in 1:7:length(days)])

    # 3. Total daily cost at the default prices.
    # One truck shift: 5.5 paid hours at 250 kr, 40% more at night, 30% social costs and 10%
    # overhead; driving at 3 kr per km plus overhead. The vehicle itself is left out.
    shift_cost(supplement) = 5.5 * 250 * (1 + supplement) * 1.30 * 1.10
    rider, truck, km = 25.0, shift_cost(0.4), 3.0 * 1.10
    numbers["truckShift"] = Dict("night" => round(truck), "day" => round(shift_cost(0.0)), "perKm" => km)
    total(run) = per_day(run) * rider + count_of(run) * truck + km_per_night(run) * km
    cheapest = argmin(total, optimal)
    bar_chart("cost.svg"; title = "Total cost a day at 25 kr per let-down rider",
              ylabel = "Thousand kroner a day", xlabel = "Optimized trucks working each night", labels = string.(count_of.(optimal)),
              values = total.(optimal) ./ 1000, colours = [run === cheapest ? NAVY : LIGHT for run in optimal])
    steps = []
    for (a, b) in zip(optimal, optimal[2:end])
        added = count_of(b) - count_of(a)
        spared = (per_day(a) - per_day(b)) / added
        push!(steps, Dict("from" => count_of(a), "to" => count_of(b), "sparedPerTruck" => round(spared),
                          "breakEven" => round((truck + (km_per_night(b) - km_per_night(a)) / added * km) / spared; digits = 1)))
    end
    numbers["cost"] = Dict("cheapest" => count_of(cheapest), "total" => round(total(cheapest)), "steps" => steps,
                           "greedyCheapest" => count_of(argmin(total, greedy)), "greedyTotal" => round(minimum(total, greedy)))

    # 4. Night against midday shifts.
    if isdir(joinpath(ROOT, "results", "day_shift"))
        shifts = filter(run -> haskey(run, "days"), read_runs("day_shift"))   # skips unfinished runs
        rows = Any[(run["night"], run["day"], run["mode"], share(run)) for run in shifts]
        totals = sort(unique(row[1] + row[2] for row in rows))
        for run in optimal
            count_of(run) in totals && push!(rows, (count_of(run), 0, "full", share(run)))
        end
        sort!(rows; by = row -> (row[1] + row[2], -row[1], row[3]))
        # The figure shows the runs where every shift plans for the rest of the day.
        drawn = [row for row in rows if row[3] == "full"]
        bar_chart("shifts.svg"; title = "The same trucks, split between night and midday", ylabel = "Riders let down over four weeks",
                  labels = ["$(row[1]) night\n$(row[2]) midday" for row in drawn], values = [row[4] for row in drawn], suffix = "%",
                  width = max(720, 56 * length(drawn)), height = 350, colours = [row[2] == 0 ? LIGHT : NAVY for row in drawn],
                  notes = [@sprintf("%.1f%%", row[4]) for row in drawn])
        numbers["shifts"] = [Dict("night" => row[1], "midday" => row[2], "mode" => row[3], "share" => round(row[4]; digits = 1)) for row in rows]
    end

    # 5. Sensitivity around four optimized night trucks.
    if isdir(joinpath(ROOT, "results", "sensitivity"))
        runs = read_runs("sensitivity")
        base = share(only(run for run in optimal if count_of(run) == 4))
        names = Dict("capacity" => v -> "$(round(Int, v)) bikes\nper truck", "shift" => v -> "$(round(v / 60; digits = 1)) hour\nshift",
                     "fleet" => v -> "$(round(Int, v))\nbikes", "handling" => v -> "$(v) min\nper bike")
        order = Dict("capacity" => 1, "shift" => 2, "handling" => 3, "fleet" => 4)
        sort!(runs; by = run -> (order[run["parameter"]], run["value"]))
        labels = vcat(["Base case"], [names[run["parameter"]](run["value"]) for run in runs])
        values = vcat([base], [Float64(run["share"]) for run in runs])
        bar_chart("sensitivity.svg"; title = "What changes if an assumption is wrong (four optimized night trucks)", ylabel = "Riders let down over four weeks",
                  labels, values, suffix = "%", colours = vcat([NAVY], fill(LIGHT, length(runs))), height = 350,
                  notes = [@sprintf("%.1f%%", v) for v in values], width = max(720, 78 * length(values)))
        numbers["sensitivity"] = vcat([Dict("parameter" => "base", "share" => round(base; digits = 1))],
                                      [Dict("parameter" => run["parameter"], "value" => run["value"], "share" => run["share"]) for run in runs])
    end

    # 6. The problem itself: the daily rhythm, the drift and two stations' curves.
    hours = [split(line, ",") for line in readlines(joinpath(ROOT, "results", "exploration", "hourly.csv"))[2:end]]
    bar_chart("hourly.svg"; title = "A summer weekday has two rush hours, and a quiet night for the trucks", ylabel = "Trips started per hour",
              xlabel = "Hour of the day", labels = [row[1] for row in hours], values = [parse(Float64, row[2]) for row in hours],
              colours = [1 <= parse(Int, row[1]) <= 5 ? NAVY : LIGHT for row in hours], notes = fill("", length(hours)), height = 300)
    drift_map("drift_map.svg")
    case = load_case(ROOT, Date(2026, 6, 1):Day(1):Date(2026, 8, 16), Date(2026, 8, 17):Day(1):Date(2026, 8, 17))
    curve_of(name) = case.weekday_curves[1][findfirst(station -> station.name == name, case.stations)]
    hill, centre = curve_of("Stavangergata"), curve_of("Tøyenbekken")
    line_chart("curves.svg"; title = "What each station wants: riders let down by how the day starts", ylabel = "Riders let down that day",
               xlabel = "Bikes at the station when the day starts (both have 30 docks)", markers = false,
               series = [("Stavangergata", BRICK, collect(0:length(hill) - 1), hill, false),
                         ("Tøyenbekken", STEEL, collect(0:length(centre) - 1), centre, false)],
               xticks = [(k, string(k)) for k in 0:5:30])
    # What the curves say is the best any set of starting levels could do on an average day.
    numbers["floor"] = Dict("weekday" => round(sum(minimum, case.weekday_curves[1]); digits = 1),
                            "weekend" => round(sum(minimum, case.weekend_curves[1]); digits = 1),
                            "bestStartBikes" => sum(argmin(curve) - 1 for curve in case.weekday_curves[1]))
    numbers["curves"] = Dict("hillBest" => argmin(hill) - 1, "hillWorst" => round(maximum(hill); digits = 1), "hillAtBest" => round(minimum(hill); digits = 1),
                             "centreBest" => argmin(centre) - 1, "centreWorst" => round(maximum(centre); digits = 1), "centreAtBest" => round(minimum(centre); digits = 1))

    open(joinpath(OUT, "numbers.json"), "w") do io
        JSON.print(io, numbers, 2)
    end
    println("wrote ", OUT)
end

main()
