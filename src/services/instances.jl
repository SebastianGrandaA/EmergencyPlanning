struct Team
    ID::String
    capacity::Int64
    cost::Float64
end

ID(team::Team)::String = team.ID

capacity(team::Team)::Int64 = team.capacity

struct Site
    ID::String
    latitude::Float64
    longitude::Float64
end

ID(site::Site)::String = site.ID

struct Neighborhood
    sites::Vector{Site}
    radius::Float64
end

struct Instance
    name::String
    sites::Vector{Site}
    demands::Array{Int64} # sites x scenarios
    teams::Vector{Team}    
    neighborhoods::Dict{String, Neighborhood}
    budget::Float64
    load_factor::Float64
end

name(instance::Instance)::String = instance.name

function Instance(filename::String)
    path = joinpath(pwd(), "inputs", "$(filename).json")
    data = JSON.parsefile(path)
    sites = [
        Site("$(SITE_PREFIX)$(idx)", coords...)
        for (idx, coords) in enumerate(data["coordinates"])
    ]
    demands = reduce(hcat, data["demands"])
    teams = [
        Team("$(TEAM_PREFIX)$(idx)", capacity, cost)
        for (idx, (capacity, cost)) in enumerate(zip(data["teamCapacities"], data["teamCost"]))
    ]
    neighborhoods = Dict(
        site.ID => Neighborhood(
            [sites[neighbor_idx + 1] for neighbor_idx in neighborhood],
            data["radius"],
        )
        for (site, neighborhood) in zip(sites, data["neighbors"])
    )
    budget, load_factor = data["budget"], data["load_factor"]

    sort!(teams, by = team -> team.capacity, rev=false)

    return Instance(filename, sites, demands, teams, neighborhoods, budget, load_factor)
end

nb_sites(instance::Instance)::Int64 = length(instance.sites)

nb_scenarios(instance::Instance)::Int64 = size(instance.demands, 2)

nb_teams(instance::Instance)::Int64 = length(instance.teams)

function maximum_radius(instance::Instance)::Float64
    return maximum(neighborhood.radius for neighborhood in values(instance.neighborhoods))
end

capacity(instance::Instance, team_idx::Int64)::Int64 = instance.teams[team_idx].capacity

maximum_capacity(instance::Instance)::Int64 = maximum(team.capacity for team in instance.teams)

total_capacity(instance::Instance)::Int64 = sum(team.capacity for team in instance.teams)

total_cost(instance::Instance)::Float64 = sum(team.cost for team in instance.teams)

maximum_rescues(instance::Instance)::Int64 = maximum_capacity(instance) * nb_sites(instance)

get_idx(team::Team)::Int64 = parse(Int64, replace(team.ID, TEAM_PREFIX => ""))

get_idx(site::Site)::Int64 = parse(Int64, replace(site.ID, SITE_PREFIX => ""))

get_idx(scenario::String)::Int64 = parse(Int64, replace(scenario, SCENARIO_PREFIX => ""))

function get_demand(instance::Instance, scenario::Int64)::Vector{Int64}
    return instance.demands[:, scenario]
end

function get_demand(instance::Instance, scenario::Int64, site::Int64)::Int64
    return get_demand(instance, scenario)[site]
end

function get_neighbor_idxs(instance::Instance, site::Site)::Vector{Int64}
    neighborhood = instance.neighborhoods[site.ID]
    
    return [get_idx(neighbor) for neighbor in neighborhood.sites]
end

function get_neighbor_idxs(instance::Instance, site_idx::Int64)::Vector{Int64}
    return get_neighbor_idxs(instance, instance.sites[site_idx])
end

"""
Scenarios with equiprobable demand
"""
function get_probability(instance::Instance)::Vector{Float64}
    probability = 1.0 / nb_scenarios(instance)

    return repeat([probability], nb_scenarios(instance))
end

function get_probability(instance::Instance, scenario::Int64)::Float64
    return get_probability(instance)[scenario]
end