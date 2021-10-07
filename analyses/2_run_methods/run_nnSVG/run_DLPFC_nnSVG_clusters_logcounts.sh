#!/bin/bash
#$ -cwd
#$ -pe local 10
#$ -l mem_free=3G,h_vmem=4G,h_fsize=100G

module load conda_R/4.1.x
/usr/bin/time -v Rscript run_DLPFC_nnSVG_clusters_logcounts.R 2> ../../../outputs/memory/nnSVG/DLPFC_nnSVG_clusters_logcounts.mem

