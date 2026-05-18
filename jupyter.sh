#!/bin/bash
#SBATCH -p gpu
#SBATCH -N 1 -c 32
#SBATCH --mem=32G
#SBATCH --gpus-per-node=1
#SBATCH --ntasks-per-node=1
#SBATCH -t 01:00:00
#SBATCH -A zz992005
#SBATCH -J jupyter
#SBATCH --nodelist=lanta-g-004

port=$(shuf -i 6000-9999 -n 1)
USER=$(whoami)
node=$(hostname -s)

ml load Miniforge3/25.3.0-3 cuda/11.8
conda activate ~/venv/

# start a cluster instance and launch the jupyter server
unset XDG_RUNTIME_DIR
if [ "$SLURM_JOBTMP" != "" ]; then
export XDG_RUNTIME_DIR=$SLURM_JOBTMP
fi
jupyter notebook --no-browser --port $port --notebook-dir=$(pwd) --ip=$node \
    --notebook-dir=/home/${USER}/workspace
