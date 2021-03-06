using Parameters
using LinearAlgebra
using StaticArrays
using Calculus
using SmoothingSplines

abstract type AbstractDomain end
export AbstractDomain

abstract type AbstractConstantKDomain <: AbstractDomain  end
export AbstractConstantKDomain

abstract type AbstractVariableKDomain <: AbstractDomain end
export AbstractVariableKDomain

@with_kw struct ConstantTPDomain{N<:AbstractPhase,S<:Integer,W<:Real, W2<:Real, I<:Integer, Q<:AbstractArray} <: AbstractConstantKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    constantspeciesinds::Array{S,1}
    T::W
    P::W
    kfs::Array{W,1}
    krevs::Array{W,1}
    efficiencyinds::Array{I,1}
    Gs::Array{W,1}
    rxnarray::Array{UInt16,2}
    mu::W = 0.0
    diffusivity::Array{W,1} = Array{Float64,1}()
    jacobian::Array{W,2} = Array{Float64,2}(undef,(0,0))
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
end
function ConstantTPDomain(;phase::E2,initialconds::Dict{X,X2},constantspecies::Array{X3,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {E<:Real,E2<:AbstractPhase,Q<:AbstractInterface,W<:Real,X,X2,X3}
    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    if sensitivity
        y0 = zeros(length(phase.species)*(1+length(phase.species)+length(phase.reactions)))
    else
        y0 = zeros(length(phase.species))
    end
    spnames = [x.name for x in phase.species]
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            y0[ind] = val
        end
    end


    @assert T != 0.0
    @assert P != 0.0
    ns = y0
    N = sum(ns)

    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    efficiencyinds = [rxn.index for rxn in phase.reactions if typeof(rxn.kinetics)<:AbstractFalloffRate && length(rxn.kinetics.efficiencies) > 0]
    Gs = calcgibbs(phase,T)
    if :solvent in fieldnames(typeof(phase)) && typeof(phase.solvent) != EmptySolvent
        mu = phase.solvent.mu(T)
    else
        mu = 0.0
    end
    if phase.diffusionlimited
        diffs = getfield.(phase.species,:diffusion)(T=T,mu=mu,P=P)
    else
        diffs = Array{typeof(T),1}()
    end
    C = P/(R*T)
    V = N*R*T/P
    kfs,krevs = getkfkrevs(phase=phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    if sparse
        jacobian=spzeros(typeof(T),length(phase.species),length(phase.species))
    else
        jacobian=zeros(typeof(T),length(phase.species),length(phase.species))
    end
    rxnarray = getreactionindices(phase)
    return ConstantTPDomain(phase,SVector(phase.species[1].index,phase.species[end].index),constspcinds,
        T,P,kfs,krevs,efficiencyinds,Gs,rxnarray,mu,diffs,jacobian,sensitivity,MVector(false),MVector(0.0)), y0
end
export ConstantTPDomain

@with_kw struct ConstantVDomain{N<:AbstractPhase,S<:Integer,W<:Real,W2<:Real,Q<:AbstractArray} <: AbstractVariableKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    constantspeciesinds::Array{S,1}
    V::W
    rxnarray::Array{UInt16,2}
    jacobian::Array{W,2}
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
end
function ConstantVDomain(;phase::Z,initialconds::Dict{X,E},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {E,X,X2,Z<:IdealGas,Q<:AbstractInterface}

    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    V = 0.0
    ns = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        elseif key == "V"
            V = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            ns[ind] = val
        end
    end
    @assert V != 0.0 || (T != 0.0 && P != 0.0)
    N = sum(ns)
    if V == 0.0
        V = N*R*T/P
    elseif T == 0.0
        T = P*V/(R*N)
    elseif P == 0.0
        P = N*R*T/V
    else
        throw(error("ConstantVDomain overspecified with T,P and V"))
    end
    if sensitivity
        y0 = vcat(ns,T,zeros((length(ns)+1)*(length(ns)+length(phase.reactions))))
    else
        y0 = vcat(ns,T)
    end
    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    if sparse
        jacobian=zeros(typeof(T),length(phase.species)+1,length(phase.species)+1)
    else
        jacobian=zeros(typeof(T),length(phase.species)+1,length(phase.species)+1)
    end
    rxnarray = getreactionindices(phase)
    return ConstantVDomain(phase,SVector(phase.species[1].index,phase.species[end].index,phase.species[end].index+1),constspcinds,
    V,rxnarray,jacobian,sensitivity,MVector(false),MVector(0.0)), y0
end
export ConstantVDomain

@with_kw struct ConstantPDomain{N<:AbstractPhase,S<:Integer,W<:Real,W2<:Real,Q<:AbstractArray} <: AbstractVariableKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    constantspeciesinds::Array{S,1}
    P::W
    rxnarray::Array{UInt16,2}
    jacobian::Array{W,2}
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
end
function ConstantPDomain(;phase::Z,initialconds::Dict{X,E},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {E,X,X2,Z<:IdealGas,Q<:AbstractInterface}

    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    V = 0.0
    ns = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        elseif key == "V"
            V = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            ns[ind] = val
        end
    end
    @assert P != 0.0 || (T != 0.0 && V != 0.0)
    N = sum(ns)
    if P == 0.0
        P = N*R*T/V
    elseif T == 0.0
        T = P*V/(R*N)
    elseif V == 0.0
        V = N*R*T/P
    else
        throw(error("ConstantPDomain overspecified with T,P and V"))
    end
    if sensitivity
        y0 = vcat(ns,T,zeros((length(ns)+1)*(length(ns)+length(phase.reactions))))
    else
        y0 = vcat(ns,T)
    end
    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    if sparse
        jacobian=zeros(typeof(T),length(phase.species)+1,length(phase.species)+1)
    else
        jacobian=zeros(typeof(T),length(phase.species)+1,length(phase.species)+1)
    end
    rxnarray = getreactionindices(phase)
    return ConstantPDomain(phase,SVector(phase.species[1].index,phase.species[end].index,phase.species[end].index+1),constspcinds,
    P,rxnarray,jacobian,sensitivity,MVector(false),MVector(0.0)), y0
end
export ConstantPDomain

@with_kw struct ParametrizedTPDomain{N<:AbstractPhase,S<:Integer,W<:Real,W2<:Real,Q<:AbstractArray} <: AbstractVariableKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    constantspeciesinds::Array{S,1}
    T::Function
    P::Function
    rxnarray::Array{UInt16,2}
    jacobian::Array{W,2}
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
end
function ParametrizedTPDomain(;phase::Z,initialconds::Dict{X,Any},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {X,X2,Z<:IdealGas,Q<:AbstractInterface}

    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    V = 0.0
    ts = 0.0
    ns = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        elseif key == "V"
            V = val
        elseif key == "ts"
            ts = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind) <: Integer  "$key not found in species list: $spnames"
            ns[ind] = val
        end
    end
    @assert V != 0.0 || (T != 0.0 && P != 0.0)
    if isa(T,AbstractArray)
        Tfcn = getspline(ts,T)
    elseif isa(T,Function)
        Tfcn = T
    else
        throw(error("ParametrizedTPDomain must take \"T\" as a function or if an array of times for \"ts\" is supplied as an array of volumes"))
    end
    if isa(P,AbstractArray)
        Pfcn = getspline(ts,P)
    elseif isa(P,Function)
        Pfcn = P
    else
        throw(error("ParametrizedTPDomain must take \"P\" as a function or if an array of times for \"ts\" is supplied as an array of volumes"))
    end

    N = sum(ns)
    V = N*R*Tfcn(0.0)/Pfcn(0.0)

    if sensitivity
        y0 = zeros(length(phase.species)*(length(phase.species)+1+length(phase.reactions)))
    else
        y0 = zeros(length(phase.species))
    end

    y0[phase.species[1].index:phase.species[end].index] = ns

    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    if sparse
        jacobian=zeros(typeof(V),length(phase.species)+1,length(phase.species)+1)
    else
        jacobian=zeros(typeof(V),length(phase.species)+1,length(phase.species)+1)
    end
    rxnarray = getreactionindices(phase)
    return ParametrizedTPDomain(phase,SVector(phase.species[1].index,phase.species[end].index),constspcinds,
    Tfcn,Pfcn,rxnarray,jacobian,sensitivity,MVector(false),MVector(0.0)), y0
end
export ParametrizedTPDomain

@with_kw struct ParametrizedVDomain{N<:AbstractPhase,S<:Integer,W<:Real,W2<:Real,Q<:AbstractArray} <: AbstractVariableKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    constantspeciesinds::Array{S,1}
    V::Function
    rxnarray::Array{UInt16,2}
    jacobian::Array{W,2}
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
end
function ParametrizedVDomain(;phase::Z,initialconds::Dict{X,Any},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {X,X2,E<:Real,Z<:IdealGas,Q<:AbstractInterface}

    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    V = 0.0
    ts = Array{Float64,1}()
    ns = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    @assert "V" in keys(initialconds)
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        elseif key == "V"
            V = val
        elseif key == "ts"
            ts = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            ns[ind] = val
        end
    end
    @assert isa(V,Function) || isa(V,AbstractArray)
    if isa(V,AbstractArray)
        Vfcn = getspline(ts,V)
    elseif isa(V,Function)
        Vfcn = V
    else
        throw(error("ParametrizedVDomain must take \"V\" as a function or if an array of times for \"ts\" is supplied as an array of volumes"))
    end
    N = sum(ns)
    if T == 0.0
        T = P*Vfcn(0.0)/(R*N)
    elseif P == 0.0
        P = N*R*T/Vfcn(0.0)
    else
        ns *= (P*Vfcn(0.0)/(R*T))/sum(ns) #automatically scale down moles if pressure specified
    end
    if sensitivity
        y0 = vcat(ns,T,zeros((length(ns)+1)*(length(ns)+length(phase.reactions))))
    else
        y0 = vcat(ns,T)
    end
    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    if sparse
        jacobian=zeros(typeof(T),length(phase.species)+1,length(phase.species)+1)
    else
        jacobian=zeros(typeof(T),length(phase.species)+1,length(phase.species)+1)
    end
    rxnarray = getreactionindices(phase)
    return ParametrizedVDomain(phase,SVector(phase.species[1].index,phase.species[end].index,phase.species[end].index+1),constspcinds,
    Vfcn,rxnarray,jacobian,sensitivity,MVector(false),MVector(0.0)), y0
end
export ParametrizedVDomain

@with_kw struct ParametrizedPDomain{N<:AbstractPhase,S<:Integer,W<:Real,W2<:Real,Q<:AbstractArray} <: AbstractVariableKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    constantspeciesinds::Array{S,1}
    P::Function
    rxnarray::Array{UInt16,2}
    jacobian::Array{W,2}
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
end
function ParametrizedPDomain(;phase::Z,initialconds::Dict{X,Any},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {X,X2,E<:Real,Z<:IdealGas,Q<:AbstractInterface}

    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    V = 0.0
    ts = Array{Float64,1}()
    ns = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    @assert "P" in keys(initialconds)
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        elseif key == "V"
            V = val
        elseif key == "ts"
            ts = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            ns[ind] = val
        end
    end
    @assert isa(P,Function) || isa(P,AbstractArray)
    if isa(P,AbstractArray)
        Pfcn = getspline(ts,P)
    elseif isa(P,Function)
        Pfcn = P
    else
        throw(error("ParametrizedPDomain must take \"P\" as a function or if an array of times for \"ts\" is supplied as an array of volumes"))
    end
    N = sum(ns)
    if T == 0.0
        T = Pfcn(0.0)*V/(R*N)
    elseif V == 0.0
        V = N*R*T/Pfcn(0.0)
    else
        ns *= (Pfcn(0.0)*V/(R*T))/sum(ns) #automatically scale down moles if volume specified
    end
    if sensitivity
        y0 = vcat(ns,T,zeros((length(ns)+1)*(length(ns)+length(phase.reactions))))
    else
        y0 = vcat(ns,T)
    end
    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    if sparse
        jacobian=zeros(typeof(T),length(phase.species)+1,length(phase.species)+1)
    else
        jacobian=zeros(typeof(T),length(phase.species)+1,length(phase.species)+1)
    end
    rxnarray = getreactionindices(phase)
    return ParametrizedPDomain(phase,SVector(phase.species[1].index,phase.species[end].index,phase.species[end].index+1),constspcinds,
    Pfcn,rxnarray,jacobian,sensitivity,MVector(false),MVector(0.0)), y0
end
export ParametrizedPDomain

@with_kw struct ConstantTVDomain{N<:AbstractPhase,S<:Integer,W<:Real, W2<:Real, I<:Integer, Q<:AbstractArray} <: AbstractConstantKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    constantspeciesinds::Array{S,1}
    T::W
    V::W
    kfs::Array{W,1}
    krevs::Array{W,1}
    efficiencyinds::Array{I,1}
    Gs::Array{W,1}
    rxnarray::Array{UInt16,2}
    mu::W = 0.0
    diffusivity::Array{W,1} = Array{Float64,1}()
    jacobian::Array{W,2} = Array{Float64,2}(undef,(0,0))
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
end
function ConstantTVDomain(;phase::Z,initialconds::Dict{X,E},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse=false,sensitivity=false) where {E,X,X2, Z<:AbstractPhase,Q<:AbstractInterface,W<:Real}
    #set conditions and initialconditions
    T = 0.0
    V = 0.0
    P = 1.0e9
    if sensitivity
        y0 = zeros(length(phase.species)*(length(phase.species)+1+length(phase.reactions)))
    else
        y0 = zeros(length(phase.species))
    end
    spnames = [x.name for x in phase.species]
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        elseif key == "V"
            V = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            y0[ind] = val
        end
    end
    @assert T != 0.0
    @assert V != 0.0
    ns = y0
    N = sum(ns)

    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    efficiencyinds = [rxn.index for rxn in phase.reactions if typeof(rxn.kinetics)<:AbstractFalloffRate && length(rxn.kinetics.efficiencies) > 0]
    Gs = calcgibbs(phase,T)
    if :solvent in fieldnames(typeof(phase)) && typeof(phase.solvent) != EmptySolvent
        mu = phase.solvent.mu(T)
    else
        mu = 0.0
    end
    if phase.diffusionlimited
        diffs = [x(T=T,mu=mu,P=P) for x in getfield.(phase.species,:diffusion)]
    else
        diffs = Array{Float64,1}()
    end
    P = 1.0e9  #essentiallly assuming this is a liquid
    C = N/V
    kfs,krevs = getkfkrevs(phase=phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    if sparse
        jacobian=zeros(typeof(T),length(phase.species),length(phase.species))
    else
        jacobian=zeros(typeof(T),length(phase.species),length(phase.species))
    end
    rxnarray = getreactionindices(phase)
    return ConstantTVDomain(phase,SVector(phase.species[1].index,phase.species[end].index),constspcinds,
        T,V,kfs,krevs,efficiencyinds,Gs,rxnarray,mu,diffs,jacobian,sensitivity,MVector(false),MVector(0.0)), y0
end
export ConstantTVDomain

@with_kw struct ParametrizedTConstantVDomain{N<:AbstractPhase,S<:Integer,W<:Real,W2<:Real,Q<:AbstractArray} <: AbstractVariableKDomain
    phase::N
    indexes::Q #assumed to be in ascending order
    constantspeciesinds::Array{S,1}
    T::Function
    V::W
    rxnarray::Array{UInt16,2}
    jacobian::Array{W,2}
    sensitivity::Bool = false
    jacuptodate::MArray{Tuple{1},Bool,1,1}=MVector(false)
    t::MArray{Tuple{1},W2,1,1}=MVector(0.0)
end
function ParametrizedTConstantVDomain(;phase::IdealDiluteSolution,initialconds::Dict{X,X3},constantspecies::Array{X2,1}=Array{String,1}(),
    sparse::Bool=false,sensitivity::Bool=false) where {X,X2,X3,Q<:AbstractInterface}
    #set conditions and initialconditions
    T = 0.0
    P = 0.0
    V = 0.0
    ts = Array{Float64,1}()
    ns = zeros(length(phase.species))
    spnames = [x.name for x in phase.species]
    @assert "V" in keys(initialconds)
    for (key,val) in initialconds
        if key == "T"
            T = val
        elseif key == "P"
            P = val
        elseif key == "V"
            V = val
        elseif key == "ts"
            ts = val
        else
            ind = findfirst(isequal(key),spnames)
            @assert typeof(ind)<: Integer  "$key not found in species list: $spnames"
            ns[ind] = val
        end
    end
    if isa(T,AbstractArray)
        Tfcn = getspline(ts,T)
    elseif isa(T,Function)
        Tfcn = T
    else
        throw(error("ParametrizedTConstantVDomain must take \"T\" as a function or if an array of times for \"ts\" is supplied as an array of volumes"))
    end
    N = sum(ns)
    if P == 0.0
        P = 1e8
    else
        throw(error("ParametrizedTConstantVDomain cannot specify P"))
    end
    if sensitivity
        y0 = zeros(length(phase.species)*(length(phase.species)+1+length(phase.reactions)))
    else
        y0 = zeros(length(phase.species))
    end
    y0[phase.species[1].index:phase.species[end].index] = ns
    if length(constantspecies) > 0
        spcnames = getfield.(phase.species,:name)
        constspcinds = [findfirst(isequal(k),spcnames) for k in constantspecies]
    else
        constspcinds = Array{Int64,1}()
    end
    if sparse
        jacobian=zeros(typeof(V),length(phase.species)+1,length(phase.species)+1)
    else
        jacobian=zeros(typeof(V),length(phase.species)+1,length(phase.species)+1)
    end
    rxnarray = getreactionindices(phase)
    return ParametrizedTConstantVDomain(phase,SVector(phase.species[1].index,phase.species[end].index),constspcinds,
    Tfcn,V,rxnarray,jacobian,sensitivity,MVector(false),MVector(0.0)), y0
end
export ParametrizedTConstantVDomain

@inline function calcthermo(d::ConstantTPDomain{W,Y},y::J,t::Q) where {W<:IdealGas,Y<:Integer,J<:AbstractArray{Float64,1},Q<:Float64}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    V = N*d.T*R/d.P
    cs = ns./V
    C = N/V
    for ind in d.efficiencyinds #efficiency related rates may have changed
        d.kfs[ind],d.krevs[ind] = getkfkrev(d.phase.reactions[ind],d.phase,d.T,d.P,C,N,ns,d.Gs,d.diffusivity,V)
    end
    return ns,cs,d.T,d.P,V,C,N,d.mu,d.kfs,d.krevs,[],[],[],[],0.0
end

@inline function calcthermo(d::ConstantTPDomain{W,Y},y::J,t::Q) where {W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        if isa(t,Float64)
            d.t[1] = t
        end
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    V = N*d.T*R/d.P
    cs = ns./V
    C = N/V
    kfs = convert(typeof(y),copy(d.kfs))
    krevs = convert(typeof(y),copy(d.krevs))
    for ind in d.efficiencyinds #efficiency related rates may have changed
        kfs[ind],krevs[ind] = getkfkrev(d.phase.reactions[ind],d.phase,d.T,d.P,C,N,ns,d.Gs,d.diffusivity,V)
    end
    return ns,cs,d.T,d.P,V,C,N,d.mu,kfs,krevs,[],[],[],[],0.0
end

@inline function calcthermo(d::ConstantVDomain{W,Y},y::J,t::Q) where {W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    N = sum(ns)
    cs = ns./d.V
    C = N/d.V
    P = C*R*T
    Gs = zeros(length(d.phase.species))
    Us = zeros(length(d.phase.species))
    Cvave = 0.0
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Us = (hdivRT.-1.0)*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=mu,P=P)
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=d.V)
    return ns,cs,T,P,d.V,C,N,0.0,kfs,krevs,[],Us,Gs,diffs,Cvave
end

@inline function calcthermo(d::ConstantPDomain{W,Y},y::J,t::Q) where {W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    N = sum(ns)
    V = N*R*T/d.P
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Hs = zeros(length(d.phase.species))
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Hs = hdivRT.*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=mu,P=d.P)
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=d.P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return ns,cs,T,d.P,V,C,N,0.0,kfs,krevs,Hs,[],Gs,diffs,Cvave
end

@inline function calcthermo(d::ParametrizedVDomain{W,Y},y::J,t::Q) where {W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    V = d.V(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    N = sum(ns)
    cs = ns./V
    C = N/V
    P = C*R*T
    Gs = zeros(length(d.phase.species))
    Us = zeros(length(d.phase.species))
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Us = (hdivRT.-1.0)*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=mu,P=P)
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return ns,cs,T,P,V,C,N,0.0,kfs,krevs,[],Us,Gs,diffs,Cvave
end

@inline function calcthermo(d::ParametrizedPDomain{W,Y},y::J,t::Q) where {W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    P = d.P(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    T = y[d.indexes[3]]
    N = sum(ns)
    V = N*R*T/P
    cs = ns./V
    C = N/V
    Gs = zeros(length(d.phase.species))
    Hs = zeros(length(d.phase.species))
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Hs = hdivRT.*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=mu,P=P)
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return ns,cs,T,P,V,C,N,0.0,kfs,krevs,Hs,[],Gs,diffs,Cvave
end

@inline function calcthermo(d::ParametrizedTConstantVDomain{W,Y},y::J,t::Q) where {W<:IdealDiluteSolution,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    V = d.V
    T = d.T(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./V
    C = N/V
    P = C*R*T
    Gs = zeros(length(d.phase.species))
    mu = d.phase.solvent.mu(T)
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    if d.phase.diffusionlimited
        diffs = [x(T=T,mu=mu,P=P) for x in getfield.(d.phase.species,:diffusion)]
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return ns,cs,T,P,V,C,N,0.0,kfs,krevs,[],[],Gs,diffs,0.0
end

@inline function calcthermo(d::ParametrizedTPDomain{W,Y},y::J,t::Q) where {W<:IdealGas,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    T = d.T(t)
    @assert T < 10000.0
    P = d.P(t)
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    V = N*T*R/P
    cs = ns./V
    C = N/V
    P = C*R*T
    Gs = zeros(length(d.phase.species))
    Us = zeros(length(d.phase.species))
    cpdivR,hdivRT,sdivR = calcHSCpdless(d.phase.vecthermo,T)
    @fastmath Gs = (hdivRT.-sdivR)*(R*T)
    @fastmath Cvave = dot(cpdivR,ns)
    @fastmath Cvave *= R/N
    @fastmath Cvave -= R
    if d.phase.diffusionlimited
        diffs = getfield.(d.phase.species,:diffusion)(T=T,mu=mu,P=P)
    else
        diffs = Array{Float64,1}()
    end
    kfs,krevs = getkfkrevs(phase=d.phase,T=T,P=P,C=C,N=N,ns=ns,Gs=Gs,diffs=diffs,V=V)
    return ns,cs,T,P,V,C,N,0.0,kfs,krevs,[],[],Gs,diffs,0.0
end

@inline function calcthermo(d::ConstantTVDomain{W,Y},y::J,t::Q) where {W<:IdealDiluteSolution,Y<:Integer,J<:AbstractArray,Q<:Real}
    if t != d.t[1]
        d.t[1] = t
        d.jacuptodate[1] = false
    end
    ns = y[d.indexes[1]:d.indexes[2]]
    N = sum(ns)
    cs = ns./d.V
    C = N/d.V
    P = 1.0e9
    return ns,cs,d.T,P,d.V,C,N,d.mu,d.kfs,d.krevs,[],[],[],[],0.0
end
export calcthermo

@inline function calcdomainderivatives!(d::Q,dydt::Array{Z7,1},interfaces::Z12;t::Z10,T::Z4,P::Z9,Us::Array{Z,1},Hs::Array{Z11,1},V::Z2,C::Z3,ns::Array{Z5,1},N::Z6,Cvave::Z8) where {Q<:AbstractDomain,Z12,Z11,Z10,Z9,Z8<:Real,Z7<:Real,W<:IdealGas,Y<:Integer,Z6,Z,Z2,Z3,Z4,Z5<:Real}
    for ind in d.constantspeciesinds #make dydt zero for constant species
        @inbounds dydt[ind] = 0.0
    end
    for inter in interfaces
        if isa(inter,Inlet) && d == inter.domain
            dydt[d.indexes[1]:d.indexes[2]] .+= inter.y.*inter.F(t)
        elseif isa(inter,Outlet) && d == inter.domain
            dydt[d.indexes[1]:d.indexes[2]] .-= inter.F(t).*ns./N
        end
    end
end

@inline function calcdomainderivatives!(d::ConstantVDomain{W,Y},dydt::Array{K,1},interfaces::Z12;t::Z10,T::Z4,P::Z9,Us::Array{Z,1},Hs::Array{Z11,1},V::Z2,C::Z3,ns::Array{Z5,1},N::Z6,Cvave::Z7) where {Z12,Z11,Z10,Z9,W<:IdealGas,Z7<:Real,K<:Real,Y<:Integer,Z6,Z,Z2,Z3,Z4,Z5<:Real}
    @views @fastmath @inbounds dydt[d.indexes[3]] = -dot(Us,dydt[d.indexes[1]:d.indexes[2]])/(N*Cvave) #divide by V to cancel ωV to ω
    for ind in d.constantspeciesinds #make dydt zero for constant species
        @inbounds dydt[ind] = 0.0
    end
    for inter in interfaces
        if isa(inter,Inlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .+= inter.y.*flow
            dydt[d.indexes[3]] += flow*(inter.H - dot(Us,ns)/N)/(N*Cvave)
        elseif isa(inter,Outlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .-= flow.*ns./N
            dydt[d.indexes[3]] -= (P*V/N*flow)/(N*Cvave)
        end
    end
end

@inline function calcdomainderivatives!(d::ConstantPDomain{W,Y},dydt::Array{K,1},interfaces::Z12;t::Z10,T::Z4,P::Z9,Us::Array{Z,1},Hs::Array{Z11,1},V::Z2,C::Z3,ns::Array{Z5,1},N::Z6,Cvave::Z7) where {Z12,Z11,Z10,Z9,W<:IdealGas,Z7<:Real,K<:Real,Y<:Integer,Z6,Z,Z2,Z3,Z4,Z5<:Real}
    @fastmath Cpave = Cvave+R
    @views @fastmath @inbounds dydt[d.indexes[3]] = -dot(Hs,dydt[d.indexes[1]:d.indexes[2]])/(N*Cpave) #divide by V to cancel ωV to ω
    for ind in d.constantspeciesinds #make dydt zero for constant species
        @inbounds dydt[ind] = 0.0
    end
    for inter in interfaces
        if isa(inter,Inlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .+= inter.y.*flow
            dydt[d.indexes[3]] += flow*(inter.H - dot(Hs,ns)/N)/(N*Cpave)
        elseif isa(inter,Outlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .-= flow.*ns./N
        end
    end
end

@inline function calcdomainderivatives!(d::ParametrizedVDomain{W,Y},dydt::Array{K,1},interfaces::Z12;t::Z10,T::Z4,P::Z9,Us::Array{Z,1},Hs::Array{Z11,1},V::Z2,C::Z3,ns::Array{Z5,1},N::Z6,Cvave::Z7) where {Z11,Z10,Z9,W<:IdealGas,Z7<:Real,K<:Real,Y<:Integer,Z6,Z,Z2,Z3,Z4,Z5<:Real,Z12}
    @views @fastmath @inbounds dydt[d.indexes[3]] = (-dot(Us,dydt[d.indexes[1]:d.indexes[2]])-P*Calculus.derivative(d.V,t))/(N*Cvave) #divide by V to cancel ωV to ω
    for ind in d.constantspeciesinds #make dydt zero for constant species
        @inbounds dydt[ind] = 0.0
    end
    for inter in interfaces
        if isa(inter,Inlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .+= inter.y.*flow
            dydt[d.indexes[3]] += flow*(inter.H - dot(Us,ns)/N)/(N*Cvave)
        elseif isa(inter,Outlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .-= flow*ns./N
            dydt[d.indexes[3]] -= (P*V/N*flow)/(N*Cvave)
        end
    end
end

@inline function calcdomainderivatives!(d::ParametrizedPDomain{W,Y},dydt::Array{K,1},interfaces::Z12;t::Z10,T::Z4,P::Z9,Us::Array{Z,1},Hs::Array{Z11,1},V::Z2,C::Z3,ns::Array{Z5,1},N::Z6,Cvave::Z7) where {Z11,Z10,Z9,W<:IdealGas,Z7<:Real,K<:Real,Y<:Integer,Z6,Z,Z2,Z3,Z4,Z5<:Real,Z12}
    @fastmath Cpave = Cvave+R
    @views @fastmath @inbounds dydt[d.indexes[3]] = (-dot(Hs,dydt[d.indexes[1]:d.indexes[2]])+V*Calculus.derivative(d.P,t))/(N*Cpave) #divide by V to cancel ωV to ω
    for ind in d.constantspeciesinds #make dydt zero for constant species
        @inbounds dydt[ind] = 0.0
    end
    for inter in interfaces
        if isa(inter,Inlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .+= inter.y.*flow
            dydt[d.indexes[3]] += flow*(inter.H - dot(Hs,ns)/N)/(N*Cpave)
        elseif isa(inter,Outlet) && d == inter.domain
            flow = inter.F(t)
            dydt[d.indexes[1]:d.indexes[2]] .-= flow.*ns./N
        end
    end
end
export calcdomainderivatives!

function getreactionindices(ig::Q) where {Q<:AbstractPhase}
    arr = zeros(UInt16,(6,length(ig.reactions)))
    for (i,rxn) in enumerate(ig.reactions)
        arr[1:length(rxn.reactantinds),i] = rxn.reactantinds
        arr[4:length(rxn.productinds)+3,i] = rxn.productinds
    end
    return arr
end
export getreactionindices

"""
fit a cubic spline to data and return a function evaluating that spline
"""
function getspline(xs,vals;s=1e-10)
    smspl = fit(SmoothingSpline,xs,vals,s)
    F(x::T) where {T} = predict(smspl,x)
    return F
end