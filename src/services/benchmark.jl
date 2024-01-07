struct Summary
    statistics::DataFrame
    plots::Plots.Plot
end

function benchmark!(model_names::Vector{String}, instance_names::Vector{String}, settings::Dict{String, Dict})::Nothing
    for instance_name in instance_names
        for model_name in model_names
            _ = optimize(instance_name, model_name; settings[model_name]...)
        end
    end

    return nothing
end

function benchmark!(model_names::Vector{String}, sample_size::Int64, settings::Dict{String, Dict})::Nothing
    path = joinpath(pwd(), "inputs")
    instance_names = [
        replace(filename, ".json" => "")
        for filename in readdir(path)
    ]

    if sample_size >= 1
        instance_names = sample(instance_names, sample_size, replace=false)
    end

    benchmark!(model_names, instance_names, settings)
end

function test(model_names::Vector{String}, results::Dict{String, Real}, settings::Dict{String, Dict})::Vector{Tuple{String, String}}
    errors = Vector{Tuple{String, String}}()

    for (instance_name, expected_result) in results
        for model_name in model_names
            solution = optimize(instance_name, model_name; settings[model_name]...)
            isapprox(objective_value(solution), expected_result; atol=1e-2) && continue

            push!(errors, (instance_name, model_name))
        end
    end

    return errors
end

"""
    plot_summary!()
    
Returns a `Summary` struct with the statistics and plots.
"""
function plot_summary!()::Summary
    path = joinpath(pwd(), "outputs", "benchmark.csv")
    data = CSV.read(path, DataFrame)
    grouped_data = groupby(data, [:model_name, :instance_name])
    stats = combine(
        grouped_data,

        :solution_value => minimum => :objective_value_min,
        :solution_value => mean => :objective_value_mean,
        :solution_value => std => :objective_value_std,
        :solution_value => maximum => :objective_value_max,
        
        :execution_time => minimum => :execution_time_min,
        :execution_time => mean => :execution_time_mean,
        :execution_time => std => :execution_time_std,        
        :execution_time => maximum => :execution_time_max,
    )

    @info "Statistical Summary" stats

    value_plot = boxplot(
        data,
        :model_name,
        :solution_value,
        title = "Objective value distribution by model",
        legend = false,
        xlabel = "Model",
        ylabel = "Objective value",
    )
    time_plot = boxplot(
        data,
        :model_name,
        :execution_time,
        title = "Execution time distribution by model",
        legend = false,
        xlabel = "Model",
        ylabel = "Execution time",
    )
    p = plot(value_plot, time_plot, layout = (2, 1))

    return Summary(stats, p)
end