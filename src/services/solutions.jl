struct Allocation
    team::Team
    site::Site
end

struct Assignment
    scenario::String
    allocation::Allocation
    nb_rescues::Real
end

scenario(assignment::Assignment)::String = assignment.scenario
allocation(assignment::Assignment)::Allocation = assignment.allocation
nb_rescues(assignment::Assignment)::Real = assignment.nb_rescues

@kwdef mutable struct Metrics
    objective_value::Real = NaN
    execution_time::Real = NaN
end

function str(metrics::Metrics)::String
    values = [
        "$(property): $(getfield(metrics, property))"
        for property in fieldnames(Metrics)
    ]
    
    return join(values, ", ")
end

struct Solution
    method::Method
    allocations::Vector{Allocation}
    rescues::Vector{Assignment}
    metrics::Metrics
end

JuMP.objective_value(solution::Solution)::Int64 = round(Int64, solution.metrics.objective_value)
execution_time(solution::Solution)::Float64 = solution.metrics.execution_time

function get_by_scenario(assignments::Vector{Assignment}, scenario::String)::Vector{Assignment}
    return filter(assignment -> get_idx(assignment.scenario) == scenario, assignments)
end