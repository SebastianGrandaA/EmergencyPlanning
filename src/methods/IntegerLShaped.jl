"""
REPORT: for illustrattive purpuses (o es la unica opcion?), utiliaz Iterative()


Binary optimality cut for a given scenario.

If x = \bar{x}, θ >= Q(x), otherwise (θ <= L)

TODO : need to create other optimality cuts apparently...


-- rappel

Let the current problem (CP) be the resulting model obtained by solving the linear relaxation of the master problem.

??Entonces en cada iteracion, o anadimos un expandimos el branch tree o agregamos cuts??


TODO revisar si en el lshaped estamos anadiendo los cuts (multi cut) pero que tenga sentido la iteracion... si anade todo de una mejor veamos si se puede hacer iterativamente.
    No seria algo como: agregar o feasibility o optimality, y resolver el master de nuevo


TODO
    check how to create async tasks for each time a node is created

TODO Always cite ! This is based on the papers of Laporte and Louveaux and the book.

                    The CurrentProblem is a master problem with a set of constraints that are not necessarily satisfied. The CurrentProblem is solved using a branch-and-bound algorithm. At each node, the integrality conditions are checked. If they are satisfied, the node is fathomed. Otherwise, two new nodes are created by branching on the first-stage binary variables. The process is repeated until all nodes are fathomed.


First-stage binary variables are taken into account. TODO IMPOERNTE!! CAMBIAR EN EL CODIGO --- yo pensaba que se debia relajar el subproblema... porque de ahi se obtienen los duales...

Vs branch and bound : nodes are not necessarily fathomed when integrality conditions are satisfied. 

Branch and cut??

1. Set the master problem and solve it
2. Add feasibility cuts
3. Check for integrality restrictions. If one violated, create two new branches following the usual branch-and-cut procedure.
4. Add optimality cuts


Recursive?
"""

struct Node
    ID::Int64
    master::Model
    metrics::Metrics
end

function is_integer(values)::Bool
    return all(isinteger.(values))
end

"""
Integrality check

We consider it is feasible if:
    * Master have a feasible (integer) solution

"""
function is_feasible(::IntegerLShaped, model::Model)::Bool
    is_allocated_integer = is_integer(value.(model[:is_allocated]))
    is_rescues_integer = is_integer(value.(model[:θ]))

    return is_allocated_integer && is_rescues_integer
end

"""
Randomly selects a branching variable from the set of non-integer variable values.
"""
function select_branching_variable(model::Model)::VariableRef
    alternatives = filter(
        variable -> !(is_integer(value.(variable))),
        all_variables(model)
    )

    return first(sample(alternatives, 1, replace=false))
end

"""

* is_search_complete : all nodes have been pruned.
"""
function should_continue(::IntegerLShaped, iteration::Int64, pendant_nodes::Vector{Node})::Bool
    iteration > MAX_SEARCH_ITERATIONS && return false

    is_search_complete = isempty(pendant_nodes)
    is_search_complete && return false

    return true
end

"""
Should prune if all variables are integer, if the LP is unfeasible or if there exists a better solution ()

Three criteria:
    Infeasibility
    Bound : the lower bound of the node is greater than the current best objective value (assuming minimization)
    Integrality: 
"""
function should_prune(method::IntegerLShaped, model::Model, best_solution::Real)::Bool
    is_unfeasible = termination_status(model) == MOI.INFEASIBLE_OR_UNBOUNDED
    is_unfeasible && return true

    all_integer = is_feasible(method, model)
    all_integer && return true

    current_value = objective_value(model)
    current_value > best_solution && return true

    return false
end

function prune!(node::Node, pendant_nodes::Vector{Node})
    initial_length = length(pendant_nodes)
    filter!(n -> n.ID != node.ID, pendant_nodes)

    is_pruned = length(pendant_nodes) == initial_length - 1
    !(is_pruned) && error("Node $(node.ID) could not be pruned from $(IDs(pendant_nodes))")
end

"""
1. Select branching variable
2. Add constraints to the lower and upper nodes
3. Solve the lower and upper nodes
"""
function add_cuts!(method::IntegerLShaped, current_node::Node, best_solution::Real, pendant_nodes::Vector{Node}, historical_nodes::Vector{Node}, node_id::Int64)::Nothing
    # Select branching variable
    branching_variable = select_branching_variable(current_node.master)
    variable_value = value(branching_variable)
    @info " | Branching on $(branching_variable)<>$(variable_value)"

    # Add two new nodes to the tree: lower and upper
    node_id += 1
    lower_node = Node(node_id, copy(current_node.master), deepcopy(current_node.metrics))
    node_id += 1
    upper_node = Node(node_id, copy(current_node.master), deepcopy(current_node.metrics))

    # Add constraints to the lower nodes and solve it
    @constraint(
        lower_node.master,
        variable_by_name(lower_node.master, string(branching_variable))
        <= floor(variable_value)
    )
    solve!(method, lower_node, best_solution, pendant_nodes, historical_nodes)

    # Add constraints to the upper nodes and solve it
    @constraint(
        upper_node.master,
        variable_by_name(upper_node.master, string(branching_variable))
        >= ceil(variable_value)
    )
    solve!(method, upper_node, best_solution, pendant_nodes, historical_nodes)

    return nothing
end

function get_best_node(nodes::Vector{Node})::Node
    _, idx = findmin(node -> node.metrics.objective_value, nodes)

    return nodes[idx]
end

"""
Assumes that node is a deepcopy
"""
function solve!(method::IntegerLShaped, node::Node, best_solution::Real, pendant_nodes::Vector{Node}, historical_nodes::Vector{Node})::Nothing
    try
        solve!(node.master)
    catch err
        @error "Node $(node.ID) : $(err)"

        return nothing
    end

    if !(should_prune(method, node.master, best_solution))
        push!(pendant_nodes, node)
        push!(historical_nodes, node)

        @info " | Node $(node.ID) created and added to pendant nodes"
    else
        @info " | Node $(node.ID) has been pruned"
    end

    return nothing
end

IDs(nodes::Vector{Node}) = [node.ID for node in nodes]

"""
# TODO la evaluacion de lower y upper puede ser en paralel (o async)
"""
function solve(method::IntegerLShaped, instance::Instance, solver::SOLVER)::Solution
    start = time()
    best_solution = nothing
    initial_solution = solve(LShaped(), instance, solver, Iterative())
    is_feasible(method, initial_solution.model) && return initial_solution

    iteration, node_id = 1, 1
    pendant_nodes = [Node(node_id, initial_solution.model, initial_solution.metrics)]
    historical_nodes = deepcopy(pendant_nodes)

    while should_continue(method, iteration, pendant_nodes)
        key = "$(str(method)) | Iteration $(iteration)"
        @info "$(key) | Pendant nodes" IDs(pendant_nodes)

        best_solution = get_best_node(historical_nodes).metrics.objective_value
        
        # Breadth-first search: select the node with the best objective value (assuming minimization)
        sort!(pendant_nodes, by=node -> node.metrics.objective_value, rev=false)
        current_node = first(pendant_nodes) # "Current Problem"

        if should_prune(method, current_node.master, best_solution)
            prune!(current_node, pendant_nodes)

            @info "$(key) | Node $(current_node.ID) has been pruned"
            continue
        end

        add_cuts!(method, current_node, best_solution, pendant_nodes, historical_nodes, node_id)
        @info "$(key) | Iteration $(iteration) completed | Cuts added"
        iteration += 1
    end

    best_solution = get_best_node(historical_nodes)
    solve!(method, best_solution, best_solution.metrics.objective_value, pendant_nodes, historical_nodes)
    @info "$(str(method)) | Tree search completed | Best solution" best_solution.metrics termination_status(best_solution.master)
    
    return Solution(
        method,
        best_solution,
        instance,
        time() - start,
    )
end

function Solution(
    method::IntegerLShaped,
    node::Node,
    instance::Instance,
    execution_time::Float64,
)
    sites = 1:nb_sites(instance)
    scenarios = 1:nb_scenarios(instance)
    teams = 1:nb_teams(instance)
    assignments = Assignment[]
    allocations = [
        Allocation(instance.teams[t], instance.sites[s])
        for s in sites, t in teams
        if value(node.master[:is_allocated][s, t]) > 0.5
    ]

    for scenario_idx in scenarios
        scenario_id = "$(SCENARIO_PREFIX)$(scenario_idx)"
        nb_rescues = value(node.master[:θ][scenario_idx])
        nb_rescues <= 0 && continue

        for s in sites
            allocation = filter(a -> a.site == instance.sites[s], allocations)
            isempty(allocation) && continue

            push!(assignments, Assignment(scenario_id, first(allocation), nb_rescues))
        end
        # TODO introduce site-dissagregation by passing the subproblem
    end
    
    metrics = Metrics(
        objective_value=round(Int64, node.metrics.objective_value),
        execution_time=execution_time,
    )
    solution = Solution(method, node.master, allocations, assignments, metrics)
    validate(solution)

    return solution
end
