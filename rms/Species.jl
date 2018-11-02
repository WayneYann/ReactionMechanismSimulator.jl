using Parameters
import Base: length
include("Calculators.jl")

abstract type AbstractSpecies end
export AbstractSpecies

@with_kw struct Species{T<:AbstractThermo,N<:AbstractDiffusivity} <: AbstractSpecies
    name::String
    index::Integer
    inchi::String = ""
    smiles::String = ""
    thermo::T
    atomnums::Dict{String,Int64} = Dict()
    bondnum::Int64=-1
    diffusion::N = EmptyDiffusivity()
    radius::Float64 = 0.0
end
export Species

length(r::T) where {T<:AbstractSpecies}= 1
export length
