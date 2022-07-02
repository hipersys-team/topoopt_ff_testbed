#!/bin/bash

#SBATCH --array=0-54
#SBATCH -o dlrmsmall-f-%a.log
#SBATCH -c 24

netopt=1
igbw=200
gdbw=256
nlat=1
local_b=128
topo="fattree"
biggpu=4
declare -a deg=(1)
declare -a bwarr=(10 25 40 80 100 160 200 320 400 800 1600)
declare -a runid=(0 1 2 3 4)
declare -a nnodes=(128)

source /etc/profile

trial=${SLURM_ARRAY_TASK_ID}
d=${deg[$(( trial % ${#deg[@]} ))]}
trial=$(( trial / ${#deg[@]} ))
b=${bwarr[$(( trial % ${#bwarr[@]} ))]}
trial=$(( trial / ${#bwarr[@]} ))
rid=${runid[$(( trial % ${#runid[@]} ))]}
trial=$(( trial / ${#bwarr[@]} ))
n=${nnodes[$(( trial % ${#nnodes[@]} ))]}

globalb=$((n*local_b*biggpu))
resultdir="a100_dlrm_${topo}_${n}_${b}_${d}_${nlat}_${local_b}_${rid}"
bash -c "cd $resultdir && $HOME/FlexFlow/ffsim-opera/src/clos/datacenter/htsim_tcp_abssw -simtime 3600.1 -flowfile ./taskgraph.fbuf -speed $((b*1000)) -ofile nwsim_abssw.txt -nodes $n -ssthresh 10000 -rtt 1000 -q 60000"
mkdir $resultdir
mv dlrmsmall-f-net-${SLURM_ARRAY_TASK_ID}.log $resultdir
