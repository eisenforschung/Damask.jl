#!/usr/bin/env julia

using HDF5

fname = "/home/m/DAMASK/examples/grid/20grains16x16x16_tensionX.hdf5"

f = h5open(fname,"r")

get = Dict()
r = r"increment_([0-9]+)"
for k in keys(f)
    if occursin(r,k)
        get[k] = Dict([("phase",Dict()),("homogenization",Dict()),("geometry",Dict())])
        for out in keys(f[k*"/geometry"])
            get[k]["geometry"][out] = read(f[k*"/geometry"*"/"*out])
        end
    end
end

println(get)
close(f)
