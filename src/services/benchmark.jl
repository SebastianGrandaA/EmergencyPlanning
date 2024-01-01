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

    if sample_size > 1
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