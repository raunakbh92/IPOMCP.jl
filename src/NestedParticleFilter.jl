type InteractiveParticleCollection{T<:InteractiveState} <: AbstractParticleInteractiveBelief{T}
    particleCollection::ParticleCollection{T}
    act_prob::Nullable{Dict{Any,Float64}} #Compute solution only once
    act_value::Nullable{Dict{Any,Float64}} #Debugging purpose
    #Compute belief update only once
    next_bel::Dict{Tuple{Any,Any},InteractiveParticleCollection{T}}
end

InteractiveParticleCollection{T<:InteractiveState}(pc::ParticleCollection{T}) =
            InteractiveParticleCollection{T}(pc,Nullable{Dict{Any,Float64}}(),Nullable{Dict{Any,Float64}}(),Dict{Tuple{Any,Any},InteractiveParticleCollection{T}}())
InteractiveParticleCollection{T<:InteractiveState}(p::AbstractVector{T}) =
                                InteractiveParticleCollection(ParticleCollection{T}(p))

n_particles(b::InteractiveParticleCollection) = n_particles(b.particleCollection)
particles(b::InteractiveParticleCollection) = particles(b.particleCollection)
weighted_particles(p::InteractiveParticleCollection) = weighted_particles(b.particleCollection)
weight_sum(::InteractiveParticleCollection) = 1.0
weight(b::InteractiveParticleCollection, i::Int) = weight(b.particleCollection,i)
particle(b::InteractiveParticleCollection, i::Int) = particle(b.particleCollection,i)
rand(rng::AbstractRNG, b::InteractiveParticleCollection) = rand(rng, b.particleCollection)
mean(b::InteractiveParticleCollection) = mean(b.particleCollection)
iterator(b::InteractiveParticleCollection) = iterator(b.particleCollection)

==(a::InteractiveParticleCollection, b::InteractiveParticleCollection) = particles(a) == particles(b)
Base.hash(a::InteractiveParticleCollection) = hash(particles(a))

function get_probs{S}(b::AbstractParticleInteractiveBelief{S})
    if isnull(b.particleCollection._probs)
        # update the cache
        probs = Dict{S, Float64}()
        for (i,p) in enumerate(particles(b))
            if haskey(probs, p)
                probs[p] += weight(b, i)/weight_sum(b)
            else
                probs[p] = weight(b, i)/weight_sum(b)
            end
        end
        b.particleCollection._probs = Nullable(probs)
    end
    return get(b.particleCollection._probs)
end

pdf{S}(b::AbstractParticleInteractiveBelief{S}, s::S) = get(get_probs(b), s, 0.0)

type SimpleInteractiveParticleFilter{S<:InteractiveState, R, RNG<:AbstractRNG} <: Updater
    ipomdp::IPOMDP_2
    resample::R
    rng::RNG
    _particle_memory::Vector{S}
    _weight_memory::Vector{Float64}
    solver::AbstractIPOMDPSolver

    SimpleInteractiveParticleFilter{S, R, RNG}(model, resample, rng, solver::AbstractIPOMDPSolver) where {S,R,RNG} = new(model, resample, rng, state_type(model)[], Float64[], solver)
end
function SimpleInteractiveParticleFilter{R}(ipomdp::IPOMDP_2, resample::R, rng::AbstractRNG, solver::AbstractIPOMDPSolver)
    return SimpleInteractiveParticleFilter{InteractiveState{state_type(ipomdp)},R,typeof(rng)}(ipomdp, resample, rng, solver)
end

#Input is an interactive particle filter, set of interactive particles, and action and observation of subject agent.
function update{IS,A,O}(up::SimpleInteractiveParticleFilter, bel::InteractiveParticleCollection{IS}, a::A, o::O, replenish_s::Nullable = Nullable())
    if haskey(bel.next_bel,(a,o))
        return bel.next_bel[(a,o)]
    end
    ipomdp = up.ipomdp
    ipomdpsolver = up.solver
    pomdpsolver = getsolver(ipomdpsolver,level(ipomdp))
    n_aj = n_oactions(ipomdp)
    ps = particles(bel)
    pm = up._particle_memory
    wm = up._weight_memory
    rng = up.rng
    resize!(pm, 0)
    resize!(wm, 0)
    #TODO: Need a better way to get n_oj
    sizehint!(pm, n_particles(bel)*n_aj*50)
    sizehint!(wm, n_particles(bel)*n_aj*50)
    all_terminal = true

    for i in 1:n_particles(bel)
        is = ps[i]
        s = is.env_state
        m_j = is.model

        if !isterminal(up.ipomdp.thisPOMDP, s)
            all_terminal = false
            if typeof(m_j) <: Intentional_Model
                frame_j = m_j.frame
                b_j = m_j.belief
                level_j = level(frame_j)
                if isnull(b_j.act_prob)
                    j_planner = solve(up.solver, frame_j)
                    b_j.act_prob = Nullable(actionProb(j_planner, b_j))
                end
                aj_prob = get(b_j.act_prob)
            else
                frame_j = m_j.frame
                hist_j = m_j.history
                j_solver = solver(frame_j, rng=rng) #NOTE: Other Subintentional models should implement the same function calls
                j_planner = solve(j_solver, frame_j)
                aj_prob = actionProb(j_planner, hist_j)
            end

            for (aj,p_aj) in aj_prob
                if p_aj < 1e-5
                    continue
                end
                pr_o = 0.0
                local sp::typeof(s)
                local r::Float64

                sp,r = generate_sr(up.ipomdp, s, a, aj, m_j.frame, rng)
                pr_o = obs_weight(up.ipomdp, s, a, aj, sp, o, m_j.frame, rng)

                if pr_o < 1e-5
                    continue
                end
                updated_model_probs = update_model(ipomdp, m_j, s, a, aj, sp, rng, up.solver)
                #modelp = rand(updated_model_probs,rng)
                for (modelp, oj_prob) in updated_model_probs
                    #println(" oj_prob = $oj_prob")
                    if oj_prob < 1e-5
                        continue
                    end
                    isp = InteractiveState(sp,modelp)
                    push!(pm, isp)
                    push!(wm, pr_o*p_aj*oj_prob)
                end
            end
        end
    end
    if all_terminal
        #error("Particle filter update error: all states in the particle collection were terminal.")
        return bel
    end
    #Particle replenishment
    if !isnull(replenish_s)
        #println("Not null")
        sp = get(replenish_s)
        is_vector = replenish(ipomdp, sp, round(Int64,n_particles(bel)* 0.1), rng)
        #println("Length of replenished is_vector = ",length(is_vector))
        for is in is_vector
            push!(pm, is)
            push!(wm, 1.0)
        end
    end
    updated_bel =  InteractiveParticleCollection(resample(up.resample, WeightedParticleBelief{IS}(pm, wm, sum(wm), nothing), up.rng))
    bel.next_bel[(a,o)] = updated_bel
    return updated_bel
end

function replenish{S}(ipomdp::IPOMDP_2, sp::S, n::Int64, rng::AbstractRNG)
    num_particles = num_nested_particles(ipomdp.thisPOMDP, ipomdp)
    lvl = level(ipomdp)
    n_frames = length(ipomdp.oaSM) + length(ipomdp.oaFrames)
    is_vector = sizehint!(Vector{InteractiveState{S}}(),n)
    for i in 1:n
        fr_id = rand(1:n_frames)
        if fr_id <= length(ipomdp.oaSM)
            si_fr = ipomdp.oaSM[fr_id]
            model = sample_model(si_fr, rng)
            push!(is_vector, InteractiveState(sp, model))
        else
            in_fr = ipomdp.oaFrames[fr_id - length(ipomdp.oaSM)]
            oa_bel_n_particles = num_particles[level(in_fr)+1]
            oa_is_vect = replenish(in_fr, sp, oa_bel_n_particles, rng)
            oa_belief = InteractiveParticleCollection(oa_is_vect)
            model = Intentional_Model(in_fr, oa_belief)
            push!(is_vector, InteractiveState(sp, model))
        end
    end

    return is_vector
end
function Base.srand(f::SimpleInteractiveParticleFilter, seed)
    srand(f.rng, seed)
    return f
end

function print(belief::InteractiveParticleCollection, numTabs::Int64=0)
    for is in particles(belief)
        print(is,numTabs)
        println()
    end
end

function get_physical_state_probability(belief::InteractiveParticleCollection)
    particle_set = particles(belief)
    n_particle = length(particle_set)
    if n_particle == 0
        return Dict{Any,Float64}()
    end
    T = typeof(particle_set[1].env_state)
    #println(T)
    st_prob = Dict{T,Float64}()
    for is in particle_set
        s = is.env_state
        #println("state = ",s," hash value = ", hash(s))
        if !(haskey(st_prob, s))
            st_prob[s] = 1.0/n_particle
        else
            st_prob[s] += 1.0/n_particle
        end
    end
    return st_prob
end

function sparse_print(belief::InteractiveParticleCollection)
    phy_st_bel = get_physical_state_probability(belief)
    print("State Prob : [")
    for (s,p) in phy_st_bel
        print(s)
        print("=>",round(p,2),", ")
    end
    print("], Action Value: [")
    if !isnull(belief.act_value)
        for (a,v) in get(belief.act_value)
            print(a)
            print("=>",round(v,2),", ")
        end
    end
    print("], Action Prob: [")
    if !isnull(belief.act_prob)
        for (a,p) in get(belief.act_prob)
            print(a)
            print("=>",round(p,2),", ")
        end
    end
    print("]")
end
