module EmergencyPlanning

using JSON
using JuMP
using Gurobi
using ArgParse
using CSV
using DataFrames
using Distributed
using StatsBase

abstract type Method end
struct Base <: Method end
struct LShaped <: Method end
struct IntegerLShaped <: Method end

abstract type ProblemType end

abstract type Usage end
struct Iterative <: Usage end
struct Callback <: Usage end

abstract type CutType end
struct Feasibility <: CutType end
struct Optimality <: CutType end

const SOLVER = MOI.OptimizerWithAttributes
const TEAM_PREFIX = "TEAM-"
const SITE_PREFIX = "SITE-"
const SCENARIO_PREFIX = "SCENARIO-"
const MAX_ITERATIONS = 2 # 4
const MAX_ITERATIONS_NO_IMPROVEMENT = floor(Int64, MAX_ITERATIONS / 2)
const SUBPROBLEM_CONSTRAINTS = 4
const DEFAULT_MATRIX = zeros(Int64, 1, 1)

include("services/instances.jl")
include("services/solutions.jl")
include("services/helpers.jl")
include("services/benchmark.jl")

include("methods/Base.jl")

include("methods/MasterProblem.jl")
include("methods/SubProblem.jl")
include("methods/LShaped.jl")
include("methods/IntegerLShaped.jl")

"""
    optimize(model_name, instance, solver)
    
Dispatches to the correct method to solve the problem and returns the solution.
Internal interface with the solvers. It dispatches to the solve function of the method and returns the solution.
"""
function optimize(model_name::String, instance::Instance, solver::SOLVER; kwargs...)::Union{Solution, Nothing}
    key = get_key(model_name, get(kwargs, :usage, nothing))
    method = nothing

    try
        method = eval(Symbol(model_name))()
    catch err
        error("Model $(model_name) not registered | Error: $err")
    end

    @info "$(key) | Instance $(instance.name) | Sites $(nb_sites(instance)) | Teams $(nb_teams(instance)) | Scenarios $(nb_scenarios(instance))"

    try
        return solve(method, instance, solver, values(kwargs)...)

    catch err
        @error "$(key) | Error while solving $(instance.name) with $(model_name) | Error: $err"

        return nothing
    end 
end

"""

External interface with the user, used in the benchmark.
"""
function optimize(instance_name::String, model_name::String; kwargs...)::Union{Solution, Nothing}
    settings = Dict(
        :filename => instance_name,
        :model => model_name,
        :limit => get(kwargs, Symbol("$(model_name)_timeout"), 1 * 60 * 60),
        :benchmark => true,
        :verbose => false,
    )
    haskey(kwargs, :usage) && push!(settings, :usage => kwargs[:usage])

    return execute(; settings...)
end

function execute(; kwargs...)::Union{Solution, Nothing}
    # Set solver
    verbose = get(kwargs, :verbose, false) == true ? 1 : 0
    solver = optimizer_with_attributes(
        Gurobi.Optimizer,
        "OutputFlag" => verbose,
        "TimeLimit" => kwargs[:limit],
    )

    # Load instance
    filename = get(kwargs, :filename, nothing)
    instance = isnothing(filename) ? kwargs[:instance] : Instance(filename)

    # Optimize
    model_name = kwargs[:model]
    params = model_params(; kwargs...)
    solution = optimize(model_name, instance, solver; params...)
    isnothing(solution) && return nothing
    show!(instance, solution)

    # Export solution
    output_path = joinpath(pwd(), "outputs")
    # export_solution(model_name, joinpath(output_path, "$(filename)_$(model_name)"), instance, solution)

    run_benchmark = get(kwargs, :benchmark, true)
    usage = get(kwargs, :usage, nothing)
    run_benchmark && add!(joinpath(output_path, "benchmark.csv"), instance, solution, usage)

    return solution
end

function main()::Nothing
    parser = ArgParseSettings()
    @add_arg_table! parser begin
        "--filename"
            help="Instance file name"
            arg_type = String
            required=true
        "--model"
            help="Model name"
            arg_type = String
            required=true
        "--limit"
            help="Time limit"
            arg_type = Int
            default=3600
    end

    _ = execute(parse_args(parser))

    return nothing
end

export main, execute, benchmark!, test

end # module EmergencyPlanning
