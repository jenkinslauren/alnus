#!/bin/sh
#SBATCH -C [intel16|intel18]
#SBATCH -N 1 -c 1
#SBATCH -t 24:00:00
#SBATCH -o /mnt/research/TIMBER/PVMvsENM/alnus/QSTAT/evals_geo_hadley.o
#SBATCH --mem 64G
#SBATCH -J evals_geo_hadley

newgrp - TIMBER

module load GCC/8.3.0 OpenMPI/3.1.4 R/4.0.2

cd /mnt/research/TIMBER/PVMvsENM/alnus/code

Rscript model_evaluations.R geo hadley alnus 'Alnus serrulata'

scontrol show job ${SLURM_JOB_ID}