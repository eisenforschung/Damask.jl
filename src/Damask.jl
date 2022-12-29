module Damask
import Base: view, get, getproperty

using HDF5, Metadata, NaturalSort, WriteVTK
export read_HDF5, get, view, place, export_VTK,getproperty


const prefix_inc = "increment_"

struct HDF5_Obj
    filename::String
    version_major::Int64
    version_minor::Int64
    structured::Bool
    cells::Vector{Int64}
    size::Vector{Float64}
    origin::Vector{Float32}
    increments::Vector{String}
    times::Vector{Float32}
    N_constituents::Int64
    N_materialpoints::Int64
    homogenizations::Vector{String}
    phases::Vector{String}
    fields::Vector{String}
    visible::Dict{String,Vector{String}}
    _protected::Bool
end

Base.show(io::IO, obj::HDF5_Obj) = begin
    str::String = string("Damask-Result-Object:\n  Filename: ", obj.filename, "\n  Visible:  increments:    ", obj.visible["increments"], "\n            phases:          ", obj.visible["phases"], "\n            homogenizations: ", obj.visible["homogenizations"], "\n            fields:          ",obj.visible["fields"],"\n")
    print(io, str, "\n")
end

function view(
    obj::HDF5_Obj;
    action::String="set", #where action in ["set","add","del"], only "set" now
    increments::Union{Int,Vector{Int},String,Vector{String},Bool,Nothing}=nothing,
    times::Union{<:AbstractFloat,Vector{<:AbstractFloat},String,Vector{String},Bool,Nothing}=nothing,
    phases::Union{String,Vector{String},Bool,Nothing}=nothing,
    homogenization::Union{String,Vector{String},Bool,Nothing}=nothing,
    fields::Union{String,Vector{String},Bool,Nothing}=nothing,
    protected::Union{Bool,Nothing}=nothing
)
    if increments !== nothing && times !== nothing
        error("\"increments\" and \"times\" are mutually exclusive")
    end

    dup = deepcopy(obj)
    for (type, input) in zip(["increments", "times", "phases", "homogenizations", "fields"], [increments, times, phases, homogenization, fields])
        if input !== nothing
            _manage_choice(dup, input, type, action)
        end
    end
    if protected !== nothing
        if protected == false
            println("Warning: Modification of existing datasets allowed")
        end
        dup._protected = protected
    end
    return dup
end

#@enum mode set add del #maybe? or parameter datatype

function _manage_choice(obj::HDF5_Obj, input::Bool, type::String, action::String)
    if type == "times"
        type = "increments"
    end
    if input == true
        _set_viewchoice(obj, getproperty(obj, Symbol(type)), type, action) #field name must be the same as type
    else
        _set_viewchoice(obj, String[], type, action)
    end
end

function _manage_choice(obj::HDF5_Obj, input::String, type::String, action::String)
    if input == "*"
        _manage_choice(obj, true, type, action)
    elseif type == "times"
        _manage_choice(obj, [parse(Float64, i)], type, action)
    else
        _set_viewchoice(obj, [input], type, action)
    end
end
function _manage_choice(obj::HDF5_Obj, input::Vector{String}, type::String, mode::String)
    if type == "times"
        _manage_choice(obj, [parse(Float64, i) for i in input], type, mode)
    else
        _set_viewchoice(obj, input, type, mode)
    end
end
#only type "increments" possible
function _manage_choice(obj::HDF5_Obj, input::Int64, type::String, action::String)
    _set_viewchoice(obj, [prefix_inc * string(input)], type, action)
end
#only type "increments" possible
function _manage_choice(obj::HDF5_Obj, input::Vector{Int64}, type::String, mode::String)
    _set_viewchoice(obj, [prefix_inc * string(i) for i in input], type, mode)
end
#only type "times" possible
function _manage_choice(obj::HDF5_Obj, input::Float64, type::String, action::String)
    _manage_choice(obj, [input], type, action)
end
#only type "times" possible
function _manage_choice(obj::HDF5_Obj, input::Vector{<:AbstractFloat}, type::String, action::String)
    choice = String[]
    for (i, time) in enumerate(getproperty(obj, Symbol(type)))
        for j in input
            if isapprox(time, j) #set parameters of isapprox?
                push!(choice, getproperty(obj, Symbol("increments"))[i])
            end
        end
    end
    _set_viewchoice(obj, choice, "increments", action)
end

function _set_viewchoice(obj::HDF5_Obj, choice::Vector{String}, type::String, action::String)
    existing = Set(obj.visible[type])
    valid = intersect(Set(choice), Set(getproperty(obj, Symbol(type))))
    if action == "set"
        obj.visible[type] = sort!([s for s in valid], lt=natural)#maybe bad: from vector to set to vector
    elseif action == "add"
        add = union(existing, valid)
        obj.visible[type] = sort!([s for s in valid], lt=natural)
    elseif action == "del"
        diff = setdiff(existing, valid)
        obj.visible[type] = sort!([s for s in valid], lt=natural)
    end
end


function get(obj::HDF5_Obj, output::Union{String,Vector{String}}="*")
    file = HDF5.h5open(obj.filename, "r")
    dict = Dict()

    all = output == "*" ? true : false
    output = output isa String ? [output] : output

    for inc in obj.visible["increments"]
        dict[inc] = Dict([("phase", Dict()), ("homogenization", Dict()), ("geometry", Dict())])
        for out in keys(file[inc*"/geometry"])
            if all || out in output
                dict[inc]["geometry"][out] = _read(file[inc*"/geometry/"*out])
            end
        end
        for ty in ["phase", "homogenization"]
            for label in obj.visible[ty*"s"]
                dict[inc][ty][label] = Dict()
                for field in keys(file[inc*"/"*ty*"/"*label])
                    if field in obj.visible["fields"]
                        dict[inc][ty][label][field] = Dict()
                        for out in keys(file[inc*"/"*ty*"/"*label*"/"*field])
                            if all || out in output
                                dict[inc][ty][label][field][out] = _read(file[inc*"/"*ty*"/"*label*"/"*field*"/"*out])
                            end
                        end
                    end
                end
            end
        end
    end
    return dict
end

function _read(dataset::HDF5.Dataset)
    d = attrs(dataset)
    meta = NamedTuple{Tuple(Symbol.(keys(d)))}(values(d))
    arr = read(dataset)
    return attach_metadata(arr, meta)
end

function place(
    obj::HDF5_Obj,
    output::Union{String,Vector{String}}="*";
    constituents::Union{Vector{Int64},Nothing}=nothing,
    fill_float::Float64=NaN,
    fill_int::Int64=0
)

    all = output == "*" ? true : false
    output = output isa String ? [output] : output

    dict::Dict{String,Dict} = Dict()

    constituents_ = constituents === nothing ? range(1, obj.N_constituents) : constituents 

    suffixes = obj.N_constituents == 1 || length(constituents_) < 2 ? [""] : ["#" * string(c) for c in constituents_]

    (at_cell_ph, in_data_ph, at_cell_ho, in_data_ho) = _mappings(obj)

    file = HDF5.h5open(obj.filename, "r")
    for inc in obj.visible["increments"]
        dict[inc] = Dict([("phase", Dict()), ("homogenization", Dict()), ("geometry", Dict())])
        for out in keys(file[inc*"/geometry"])
            if all || out in output
                dict[inc]["geometry"][out] = _read(file[inc*"/geometry/"*out])
            end
        end
        for ty in ["phase", "homogenization"]
            for label in obj.visible[ty*"s"]
                for field in keys(file[inc*"/"*ty*"/"*label])
                    if field in obj.visible["fields"]
                        if !(field in keys(dict[inc][ty]))
                            dict[inc][ty][field] = Dict()
                        end
                        for out in keys(file[inc*"/"*ty*"/"*label*"/"*field])
                            if all || out in output
                                data = _read(file[inc*"/"*ty*"/"*label*"/"*field*"/"*out])
                                type = eltype(parent(data))
                                fill_val = type <: Integer ? Int32(fill_int) : Float32(fill_float)
                                if ty == "phase"
                                    if !(out * suffixes[1] in keys(dict[inc][ty][field]))
                                        for suffix in suffixes
                                            dict[inc][ty][field][out*suffix] = _empty_like(obj, data, fill_val)
                                        end
                                    end
                                    for (c, suffix) in zip(constituents_, suffixes)
                                        if ndims(data) == 3
                                            dict[inc][ty][field][out*suffix][:, :, at_cell_ph[c][label]] = data[:, :, in_data_ph[c][label]]
                                        elseif ndims(data) == 2
                                            dict[inc][ty][field][out*suffix][:, at_cell_ph[c][label]] = data[:, in_data_ph[c][label]]
                                        end
                                    end
                                end
                                if ty == "homogenization"
                                    if !(out in keys(dict[inc][ty][field]))
                                        dict[inc][ty][field][out] = _empty_like(obj, data, fill_val)
                                    end
                                    if ndims(data) == 2
                                        dict[inc][ty][field][out][:, at_cell_ho[label]] = data[:, in_data_ho[label]]
                                    elseif ndims(data) == 1
                                        dict[inc][ty][field][out][at_cell_ho[label]] = data[in_data_ho[label]]
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return dict
end

function export_VTK(obj::HDF5_Obj,
    output::Union{String,Vector{String}}="*";
    mode::String="cell", #only cell-mode now
    constituents::Union{Vector{Int64},Nothing}=nothing,
    fill_float::Float64=NaN,
    fill_int::Int64=0,
    parallel::Bool=true #does nothing now
)

    if lowercase(mode) == "cell"
        mode = "cell"
    elseif lowercase(mode) == "point"
        mode = "point"
    else
        error("invalid mode: " * mode)
    end

    all = output == "*" ? true : false
    output = output isa String ? [output] : output

    constituents_ = constituents === nothing ? range(1, obj.N_constituents) : constituents
    suffixes = obj.N_constituents == 1 || length(constituents_) < 2 ? [""] : ["#" * string(c) for c in constituents_]

    (at_cell_ph, in_data_ph, at_cell_ho, in_data_ho) = _mappings(obj)

    file = HDF5.h5open(obj.filename, "r")

    cells = read_attribute(file["geometry"], "cells")
    origin = read_attribute(file["geometry"], "origin")
    size = read_attribute(file["geometry"], "size")

    x = (origin[1]:size[1]-origin[1]:cells[1]) / cells[1]
    y = (origin[2]:size[2]-origin[2]:cells[2]) / cells[2]
    z = (origin[3]:size[3]-origin[3]:cells[3]) / cells[3]

    n_digits = ndigits(parse(Int64, split(obj.increments[end], prefix_inc)[end]))

    for inc in obj.visible["increments"]
        k_inc = parse(Int64, split(inc, prefix_inc)[end])
        vtkfile = vtk_grid(_trunc_name(obj.filename) * "_increm" * string(k_inc, pad=n_digits), x, y, z) #TODO different for mode "point" ?

        vtkfile["created", VTKFieldData()] = read_attribute(file, "creator") * " (" * read_attribute(file, "created") * ")"
        if mode == "cell"
            vtkfile["u"] = _read(file[inc*"/geometry/u_n"])
        else
            vtkfile["u"] = _read(file[inc*"/geometry/u_p"])
        end
        for ty in ["phase", "homogenization"]
            for field in obj.visible["fields"]
                outs = Dict()
                for label in obj.visible[ty*"s"]
                    if field in keys(file[inc*"/"*ty*"/"*label])
                        for out in keys(file[inc*"/"*ty*"/"*label*"/"*field])
                            if all || out in output
                                data = _read(file[inc*"/"*ty*"/"*label*"/"*field*"/"*out])
                                fill_val = eltype(parent(data)) <: Integer ? Int32(fill_int) : Float32(fill_float)
                                if ty == "phase"
                                    if !(out * suffixes[1] in keys(outs))
                                        for suffix in suffixes
                                            outs[out*suffix] = _empty_like(obj, data, fill_val)
                                        end
                                    end
                                    for (c, suffix) in zip(constituents_, suffixes)
                                        if ndims(data) == 3
                                            outs[out*suffix][:, :, at_cell_ph[c][label]] = data[:, :, in_data_ph[c][label]]
                                        elseif ndims(data) == 2
                                            outs[out*suffix][:, at_cell_ph[c][label]] = data[:, in_data_ph[c][label]]
                                        end
                                    end
                                end
                                if ty == "homogenization"
                                    if !(out in keys(outs))
                                        outs[out] = _empty_like(obj, data, fill_val)
                                    end
                                    if ndims(data) == 2
                                        outs[out][:, at_cell_ho[label]] = data[:, in_data_ho[label]]
                                    elseif ndims(data) == 1
                                        outs[out][at_cell_ho[label]] = data[in_data_ho[label]]
                                    end
                                end
                            end
                        end
                    end
                end
                for (label, dataset) in outs
                    vtkfile["/"*ty*"/"*field*"/"*label*" / "*dataset.unit] = dataset
                end
            end
        end
        vtk_save(vtkfile)
    end
end

function _empty_like(obj::HDF5_Obj, dataset, fill_val)
    shape = (size(dataset)[1:end-1]..., obj.N_materialpoints)
    return attach_metadata(fill(fill_val, shape), metadata(dataset))
end

function _mappings(obj::HDF5_Obj)
    file = HDF5.h5open(obj.filename, "r")

    at_cell_ph = [Dict{String,Vector{Int64}}() for _ in 1:obj.N_constituents]
    in_data_ph = [Dict{String,Vector{Int64}}() for _ in 1:obj.N_constituents]
    at_cell_ho = Dict{String,Vector{Int64}}()
    in_data_ho = Dict{String,Vector{Int64}}()
    phase_dset = file["cell_to/phase"][1:end, 1:end]
    phase = getindex.(phase_dset, :label)
    homogenization_dset = file["cell_to/homogenization"][1:end]
    homogenization = getindex.(homogenization_dset, :label)

    for c in range(1, obj.N_constituents)
        for label in obj.visible["phases"]
            at_cell_ph[c][label] = findall(x -> x == label, phase[c, :])
            in_data_ph[c][label] = getindex.(phase_dset[c, at_cell_ph[c][label]], :entry) .+ 1 # plus 1 because Julia is 1-based
        end
    end
    for label in obj.visible["homogenizations"]
        at_cell_ho[label] = findall(x -> x == label, homogenization)
        in_data_ho[label] = getindex.(homogenization_dset[at_cell_ho[label]], :entry) .+ 1
    end

    return (at_cell_ph, in_data_ph, at_cell_ho, in_data_ho)
end

function _trunc_name(filename::String)
    arr = split(filename, "\\")
    trunc = split(arr[end], ".")
    return trunc[1]
end


function read_HDF5(filename::String)
    #no hdf5 file?
    if !HDF5.ishdf5(filename)
        error("No HDF5-file") 
    end
    file = HDF5.h5open(filename, "r") # "r": read-only 

    # right version
    version_minor = HDF5.read_attribute(file, "DADF5_version_minor")
    version_major = HDF5.read_attribute(file, "DADF5_version_major")
    if version_major != 0 || version_minor < 12 || version_minor > 14
        error("unsupported DADF5 version ", version_major, ".", version_minor)
    end
    export_setup = true #?
    if version_major == 0 && version_minor < 14
        export_setup = false #?
    end

    #Structured
    structured = haskey(HDF5.attributes(file["geometry"]), "cells")
    if structured
        cells = HDF5.read_attribute(file["geometry"], "cells")
        _size = HDF5.read_attribute(file["geometry"], "size") #dont name variable size because conflict
        origin = HDF5.read_attribute(file["geometry"], "origin")
    end

    #read increments
    increments = [i for i in keys(file) if occursin(Regex("$prefix_inc([0-9]+)"), i)]
    increments = sort!(increments, lt=natural)
    if length(increments) == 0
        error("no increments found")
    end

    times = [round(HDF5.read_attribute(file[i], "t/s")) for i in increments]
    (N_constituents, N_materialpoints) = size(file["cell_to/phase"]) #other way around in python, because Julia is column-major

    homogenization = getindex.(file["cell_to/homogenization"][1:end], :label)
    homogenizations = unique!(sort!(homogenization))

    phase = getindex.(file["cell_to/phase"][1:end, 1:end], :label)
    phases = unique!(sort!(vec(phase))) #sorting algo? vec() for 1D-Array

    fields = String[]
    for c in phases
        append!(fields, keys(file[string("/", increments[1], "/phase/", c)]))
    end
    for m in homogenizations
        append!(fields, keys(file[string("/", increments[1], "/homogenization/", m)]))
    end
    fields = unique!(sort!(fields))

    visible = Dict{String,Vector{String}}("increments" => increments,
        "phases" => phases,
        "homogenizations" => homogenizations,
        "fields" => fields,
    )

    _protected = true
    close(file)
    return HDF5_Obj(filename, version_major, version_minor, structured, cells, _size, origin, increments, times, N_constituents, N_materialpoints, homogenizations, phases, fields, visible, _protected)
end

end   #end of module