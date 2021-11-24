using ITensors
using ITensorVisualization
using Graphs
using GLMakie

g = grid((5,))
tn = itensornetwork(g; linkspaces=10, sitespaces=2)
@visualize fig tn backend = "Makie"

fig