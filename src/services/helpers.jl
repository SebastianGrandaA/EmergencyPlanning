function solve!(model::Model)::Nothing
    optimize!(model)
    validate(model)
end

function validate(model::Model)::Nothing
    to_optimality = termination_status(model) == MOI.OPTIMAL

    !(to_optimality) && @warn "Model not optimal | Objective value $(objective_value(model))"

    return nothing
end

function validate(solution::Solution)::Nothing
    # TODO add validations
    @info "Solution is valid"
end

function to_df(solution::Solution)::Vector{DataFrame}
    allocations = DataFrame(team=String[], site=String[])
    for allocation in solution.allocations
        push!(allocations, [ID(allocation.team), ID(allocation.site)])
    end

    rescues = DataFrame(scenario=String[], team=String[], site=String[], nb_rescues=Real[])
    for assignment in solution.rescues
        push!(rescues, [
            scenario(assignment),
            ID(allocation(assignment).team),
            ID(allocation(assignment).site),
            nb_rescues(assignment),
        ])
    end

    metrics = DataFrame(
        objective_value=[objective_value(solution)],
        execution_time=[execution_time(solution)],
    )

    return [allocations, rescues, metrics]
end

function str(instance::Instance)::String
    return "Instance $(name(instance)) | Sites $(nb_sites(instance)) | Teams $(nb_teams(instance)) | Scenarios $(nb_scenarios(instance))"
end

function show!(instance::Instance, solution::Solution)
    @info str(instance)

    for df in to_df(solution)
        @info df
    end
end

function model_params(; kwargs...)::Dict{Symbol, Any}
    params = Dict{Symbol, Any}()
    usage = get(kwargs, :usage, nothing)

    if !(isnothing(usage))
        if usage == :iterative # TODO refactor to use a function
            push!(params, :usage => Iterative())
        elseif usage == :callback
            push!(params, :usage => Callback())
        else
            error("Usage $(usage) not registered")
        end
    end

    return params
end

JuMP.objective_value(problem::ProblemType)::Real = problem.metrics.objective_value

str(method::Method)::String = last(split(string(typeof(method)), "."))
str(usage::Usage)::String = last(split(string(typeof(usage)), "."))

function get_key(method::String, usage::Union{Symbol, String, Nothing})::String
    isnothing(usage) && return method

    return "$(method)-$(string(usage))"
end

get_key(method::Method, usage::Union{Symbol, String, Nothing})::String = get_key(str(method), usage)

get_key(method::Union{Method, String}, usage::Usage)::String = get_key(method, str(usage))

method(solution::Solution)::Method = solution.method

function get_file(name::String, columns::Vector{String})::DataFrame
    if isfile(name)
        data = CSV.read(name, DataFrame)

        if all(c -> c in names(data), columns)
            return data
        end
    end

    return DataFrame(Dict(c => [] for c in columns))
end

function add!(
    filename::String, 
    instance::Instance, 
    solution::Solution, 
    usage::Union{Symbol, Nothing}
)::Nothing
    # TODO the resulting CSV has incorrect column names - small fix
    columns = ["instance_name", "model_name", "solution_value", "execution_time"]
    history = get_file(filename, columns)
    execution = [
        name(instance),
        get_key(method(solution), usage),
        objective_value(solution),
        execution_time(solution)
    ]
    push!(history, execution, promote=true)
    @info "Solution recorded in benchmark file"

    CSV.write(filename, history)

    return nothing
end