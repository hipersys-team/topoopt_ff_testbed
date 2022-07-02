#!/bin/bash

#SBATCH --array=0-19
#SBATCH -o dlrmsmall128-%a.log
#SBATCH --gres=gpu:volta:1
#SBATCH -c 20

netopt=1
igbw=200
gdbw=256
nlat=1
local_b=128
biggpu=4
declare -a deg=(4 6)
declare -a bwarr=(40 100)
declare -a runid=(0 1 2 3 4)
declare -a nnodes=(128)
declare -a topologies=("topoopt")

source /etc/profile
module load cuda/11.3

trial=${SLURM_ARRAY_TASK_ID}
d=${deg[$(( trial % ${#deg[@]} ))]}
trial=$(( trial / ${#deg[@]} ))
b=${bwarr[$(( trial % ${#bwarr[@]} ))]}
trial=$(( trial / ${#bwarr[@]} ))
rid=${runid[$(( trial % ${#runid[@]} ))]}
trial=$(( trial / ${#runid[@]} ))
n=${nnodes[$(( trial % ${#nnodes[@]} ))]}
trial=$(( trial / ${#nnodes[@]} ))
topo=${topologies[$(( trial % ${#topologies[@]} ))]}

globalb=$((n*local_b*biggpu))
mfile="/home/gridsan/weiyangw/FlexFlow/measures/dlrm128.json"
resultdir="a100_dlrm_${topo}_${n}_${b}_${d}_${nlat}_${local_b}_${rid}"
/home/gridsan/weiyangw/FlexFlow/build/Release/examples/cpp/DLRMsim/dlrmsim -ll:gpu 1 -ll:cpu 1 -ll:zsize 20000 -ll:fsize 10000 -ll:util 4 -dm:memoize --embedding-bag-size 100 --arch-sparse-feature-size 128 --arch-embedding-size 10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000-10000000 --arch-mlp-bot 2048-2048-2048-2048-2048-2048-2048-2048 --arch-mlp-top 4096-4096-4096-4096-4096-4096-4096-4096-4096-4096-4096-4096-4096-4096-4096-4096-1  --batch-size ${globalb} --interface-bandwidth $b --inter-gpu-bandwidth $igbw --gpu-dram-bandwidth $gdbw --network-latency $nlat --net-opt $netopt --nsimnode $n --search-budget 4000 --mfile $mfile  --enable-propagation --node-degree $d --taskgraph taskgraph_$SLURM_ARRAY_TASK_ID.fbuf --simulator-workspace-size 65536 --big-gpu $biggpu --topology $topo
mkdir $resultdir
mv taskgraph_$SLURM_ARRAY_TASK_ID.fbuf $resultdir/taskgraph.fbuf
mv dlrmsmall128-${SLURM_ARRAY_TASK_ID}.log $resultdir
