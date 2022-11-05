#!/usr/bin/env julia

using WriteVTK
using HDF5

fname = "/home/m/DAMASK/examples/grid/20grains16x16x16_tensionX.hdf5"

f = h5open(fname,"r")
cells = read_attribute(f["geometry"],"cells")
origin = read_attribute(f["geometry"],"origin")
size = read_attribute(f["geometry"],"size")

x = origin[1]:size[1]-origin[1]:cells[1]
y = origin[2]:size[2]-origin[2]:cells[2]
z = origin[3]:size[3]-origin[3]:cells[3]


vtk_grid("my_dataset", x, y, z) do vtk
        vtk["u_n"] = read(f["increment_0/geometry/u_n"])
end

close(f)
