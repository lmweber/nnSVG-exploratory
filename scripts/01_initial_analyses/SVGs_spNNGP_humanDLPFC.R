#########################
# SVGs spNNGP example
# Lukas Weber, March 2021
#########################

# ---------------------------------------------
# Load data, preprocessing, calculate logcounts
# ---------------------------------------------

# Code copied from current version of OSTA

# LOAD DATA

library(SpatialExperiment)
library(STexampleData)
spe <- load_data("Visium_humanDLPFC")

# QUALITY CONTROL (QC)

library(scater)
# subset to keep only spots over tissue
spe <- spe[, spatialData(spe)$in_tissue == 1]
# identify mitochondrial genes
is_mito <- grepl("(^MT-)|(^mt-)", rowData(spe)$gene_name)
# calculate per-spot QC metrics
spe <- addPerCellQC(spe, subsets = list(mito = is_mito))
# select QC thresholds
qc_lib_size <- colData(spe)$sum < 500
qc_detected <- colData(spe)$detected < 250
qc_mito <- colData(spe)$subsets_mito_percent > 30
qc_cell_count <- colData(spe)$cell_count > 12
# combined set of discarded spots
discard <- qc_lib_size | qc_detected | qc_mito | qc_cell_count
colData(spe)$discard <- discard
# filter low-quality spots
spe <- spe[, !colData(spe)$discard]

# NORMALIZATION

library(scran)
# quick clustering for pool-based size factors
set.seed(123)
qclus <- quickCluster(spe)
# calculate size factors
spe <- computeSumFactors(spe, cluster = qclus)
# calculate logcounts (log-transformed normalized counts)
spe <- logNormCounts(spe)

# FEATURE SELECTION

# remove mitochondrial genes
spe <- spe[!is_mito, ]
# fit mean-variance relationship
dec <- modelGeneVar(spe)
# select top HVGs
top_hvgs <- getTopHVGs(dec, prop = 0.1)


# -----------------
# Fit spNNGP models
# -----------------

# fitting a single model for one gene for now for testing purposes
# there are several tricks for speeding up a loop over all genes, including:
# - parallelization (one thread per gene)
# - re-use nearest neighbors info using argument 'neighbor.info'
# - filter out low-expressed genes and/or restrict to a set of top HVGs

# using logcounts for now
# but spNNGP can also fit discrete responses (counts)

library(spNNGP)

y <- logcounts(spe)
dim(y)

coords <- spatialCoords(spe)
dim(coords)
head(coords)
# scale coordinates
coords <- apply(coords, 2, function(col) (col - min(col)) / (max(col) - min(col)))

# parameters from example in spatial statistics course
n.samples <- 2000
starting <- list("phi" = 3/0.5, "sigma.sq" = 50, "tau.sq" = 1)
tuning <- list("phi" = 0.05, "sigma.sq" = 0.05, "tau.sq" = 0.05)
p <- 1
priors <- list("beta.Norm" = list(rep(0, p), diag(1000, p)), 
               "phi.Unif" = c(3/1, 3/0.1), "sigma.sq.IG" = c(2, 2), 
               "tau.sq.IG" = c(2, 0.1))


# -------------------------------------------
# Example: fit spNNGP model for a single gene
# -------------------------------------------

# extract responses for one gene
ix <- which(rowData(spe)$gene_name == "PCP4")
ix

# convert to dense vector
y_pcp4 <- y[ix, ]

stopifnot(length(y_pcp4) == nrow(coords))

# fit spNNGP model for a single gene
# runtime: around 30 sec (for one gene - but scaling linearly in number of spots)
out_spnngp <- spNNGP(y_pcp4 ~ 1, coords = coords, starting = starting, method = "latent", n.neighbors = 5, 
                     tuning = tuning, priors = priors, cov.model = "exponential", 
                     n.samples = n.samples, return.neighbor.info = TRUE, n.omp.threads = 1)

# some outputs
# see documentation ?spNNGP for complete list

# matrix of posterior samples for spatial random effects (rows = spots, columns = posterior samples)
dim(out_spnngp$p.w.samples)
out_spnngp$p.w.samples[1:6, 1995:2000]

# nearest neighbor info that can be re-used in loop (may only be a small fraction of total runtime though)
str(out_spnngp$neighbor.info, max.level = 1)

# total runtime (for one gene)
out_spnngp$run.time


# outputs that can be used for ranking SVGs

# sum of absolute values of medians of posterior samples for spatial random effects
library(matrixStats)
med_spraneff <- rowMedians(out_spnngp$p.w.samples)
length(med_spraneff)
# sum of absolute values across spots
sum_abs_med_spraneff <- sum(abs(med_spraneff))
sum_abs_med_spraneff


# compare to some random gene
head(rowData(spe))
sum(y[4, ])
out_spnngp <- spNNGP(y[4, ] ~ 1, coords = coords, starting = starting, method = "latent", n.neighbors = 5, 
                     tuning = tuning, priors = priors, cov.model = "exponential", 
                     n.samples = n.samples, return.neighbor.info = TRUE, n.omp.threads = 1)
# sum of absolute values of medians of posterior samples for spatial random effects
med_spraneff <- rowMedians(out_spnngp$p.w.samples)
length(med_spraneff)
# sum of absolute values across spots
sum_abs_med_spraneff <- sum(abs(med_spraneff))
sum_abs_med_spraneff


# ----------------------------------
# Parallelized loop across all genes
# ----------------------------------

# first filter out low-expressed genes

# number of genes: 33,525
nrow(spe)
# keep genes with at least the following UMI count in at least one spot
minmax_count <- 5
ix_keep <- apply(counts(spe), 1, function(row) any(row >= minmax_count))
# number of genes remaining: 3,167
table(ix_keep)
spe_sub <- spe[ix_keep, ]
n_keep <- nrow(spe_sub)

# parallelized loop
library(BiocParallel)
library(spNNGP)
library(matrixStats)
y <- logcounts(spe_sub)
dim(y)
n_threads = 20

runtime_spnngp <- system.time({
  out_spnngp <- bplapply(seq_len(n_keep), function(i) {
    # fit spNNGP model for one gene
    out_i <- spNNGP(y[i, ] ~ 1, coords = coords, starting = starting, method = "latent", n.neighbors = 5, 
                    tuning = tuning, priors = priors, cov.model = "exponential", 
                    n.samples = n.samples, return.neighbor.info = TRUE, n.omp.threads = 1)
    # sum of absolute values of medians of posterior samples for spatial random effects
    list(
      spnngp_abs = sum(abs(rowMedians(out_i$p.w.samples))), 
      spnngp_sq = sum((rowMedians(out_i$p.w.samples))^2)
    )
  }, BPPARAM = MulticoreParam(workers = n_threads))
})

# collapse list
mat_spnngp <- do.call("rbind", out_spnngp)
mat_spnngp <- apply(mat_spnngp, 2, as.numeric)
head(mat_spnngp)
dim(mat_spnngp)
str(mat_spnngp)


# outputs
stopifnot(nrow(mat_spnngp) == nrow(spe_sub))

rowData(spe_sub) <- cbind(rowData(spe_sub), mat_spnngp)
rowData(spe_sub)

# reverse ranks
rowData(spe_sub)$rank_abs <- rank(-1 * rowData(spe_sub)$spnngp_abs)
rowData(spe_sub)$rank_sq <- rank(-1 * rowData(spe_sub)$spnngp_sq)

head(rowData(spe_sub))


# runtime
runtime_spnngp


# top genes
rowData(spe_sub)[rowData(spe_sub)$rank_spnngp <= 10, c(1, 2, 4, 5)]
# PCP4
rowData(spe_sub)[rowData(spe_sub)$gene_name == "PCP4", c(1, 2, 4, 5)]
# favorites
favorites <- c("MOBP", "PCP4", "SNAP25", "HBB", "IGKC", "NPY")
rowData(spe_sub)[rowData(spe_sub)$gene_name %in% favorites, c(1, 2, 4, 5)]


# -----------------
# Compare with HVGs
# -----------------

as.data.frame(rowData(spe_sub)[head(top_hvgs, 40), c(1, 2, 4, 5)])


# -----------------------
# Compare with total UMIs
# -----------------------

library(ggplot2)

# total UMIs
rowData(spe_sub)$sum <- rowSums(counts(spe_sub))
head(rowData(spe_sub))
# mean log-expression
rowData(spe_sub)$meanlogexp <- rowMeans(logcounts(spe_sub))
head(rowData(spe_sub))
# loess fit
rowData(spe_sub)$loess_fit_abs <- predict(loess(rowData(spe_sub)$spnngp_abs ~ rowData(spe_sub)$meanlogexp))
rowData(spe_sub)$loess_fit_sq <- predict(loess(rowData(spe_sub)$spnngp_sq ~ rowData(spe_sub)$meanlogexp))
rowData(spe_sub)$loess_resid_abs <- rowData(spe_sub)$spnngp_abs - rowData(spe_sub)$loess_fit_abs
rowData(spe_sub)$loess_resid_sq <- rowData(spe_sub)$spnngp_sq - rowData(spe_sub)$loess_fit_sq
# rank by residuals for loess fit
rowData(spe_sub)$rank_loess_abs <- rank(-1 * rowData(spe_sub)$loess_resid_abs)
rowData(spe_sub)$rank_loess_sq <- rank(-1 * rowData(spe_sub)$loess_resid_sq)
# gam fit
library(mgcv)
rowData(spe_sub)$gam_fit_abs <- as.numeric(predict(gam(rowData(spe_sub)$spnngp_abs ~ s(rowData(spe_sub)$meanlogexp), bs = "cs")))
rowData(spe_sub)$gam_fit_sq <- as.numeric(predict(gam(rowData(spe_sub)$spnngp_sq ~ s(rowData(spe_sub)$meanlogexp), bs = "cs")))
rowData(spe_sub)$gam_resid_abs <- rowData(spe_sub)$spnngp_abs - rowData(spe_sub)$gam_fit_abs
rowData(spe_sub)$gam_resid_sq <- rowData(spe_sub)$spnngp_sq - rowData(spe_sub)$gam_fit_sq
# rank by residuals for gam fit
rowData(spe_sub)$rank_gam_abs <- rank(-1 * rowData(spe_sub)$gam_resid_abs)
rowData(spe_sub)$rank_gam_sq <- rank(-1 * rowData(spe_sub)$gam_resid_sq)

rowData(spe_sub)


# compare with HVGs
rowData(spe_sub)$hvgs_bio <- dec[rownames(spe_sub), "bio"]
rowData(spe_sub)$hvgs_rank <- rank(-1 * rowData(spe_sub)$hvgs_bio)


# top genes
rowData(spe_sub)[rowData(spe_sub)$rank_gam_abs <= 10, ]
rowData(spe_sub)[rowData(spe_sub)$rank_gam_sq <= 10, ]


# plots
png("spnngp_abs_vs_meanlogexp_loess.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = meanlogexp, y = spnngp_abs)) + 
  geom_point() + 
  geom_line(aes(x = meanlogexp, y = loess_fit_abs), color = "blue", size = 1.5) + 
  theme_bw()
dev.off()

png("spnngp_sq_vs_meanlogexp_loess.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = meanlogexp, y = spnngp_sq)) + 
  geom_point() + 
  geom_line(aes(x = meanlogexp, y = loess_fit_sq), color = "red", size = 1.5) + 
  theme_bw()
dev.off()

png("loess_resid_abs_vs_rank.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = rank_loess_abs, y = loess_resid_abs)) + 
  geom_point() + 
  scale_x_reverse() + 
  theme_bw()
dev.off()

png("spnngp_abs_vs_rank_loess.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = rank_loess_abs, y = spnngp_abs)) + 
  geom_point() + 
  scale_x_reverse() + 
  theme_bw()
dev.off()


# alternative using gam
png("spnngp_abs_vs_meanlogexp_gam.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = meanlogexp, y = spnngp_abs)) + 
  geom_point() + 
  geom_line(aes(x = meanlogexp, y = gam_fit_abs), color = "blue", size = 1.5) + 
  theme_bw()
dev.off()

png("spnngp_sq_vs_meanlogexp_gam.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = meanlogexp, y = spnngp_sq)) + 
  geom_point() + 
  geom_line(aes(x = meanlogexp, y = gam_fit_sq), color = "red", size = 1.5) + 
  theme_bw()
dev.off()

png("gam_resid_abs_vs_rank.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = rank_gam_abs, y = gam_resid_abs)) + 
  geom_point() + 
  scale_x_reverse() + 
  theme_bw()
dev.off()

png("spnngp_abs_vs_rank_gam.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = rank_gam_abs, y = spnngp_abs)) + 
  geom_point() + 
  scale_x_reverse() + 
  theme_bw()
dev.off()


# compare with and without subtracting from loess
png("loesscomparison_loess_resid_abs_vs_spnngp_abs.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = spnngp_abs, y = loess_resid_abs)) + 
  geom_point() + 
  theme_bw()
dev.off()


# compare with HVGs

png("HVGScomparison_loess_resid_abs_vs_hvgs_bio.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = hvgs_bio, y = loess_resid_abs)) + 
  geom_point() + 
  theme_bw()
dev.off()

png("HVGScomparison_rank_loess_abs_vs_hvgs_rank.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = hvgs_rank, y = rank_loess_abs)) + 
  geom_point() + 
  theme_bw()
dev.off()


png("HVGScomparison_spnngp_abs_vs_hvgs_bio.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = hvgs_bio, y = spnngp_abs)) + 
  geom_point() + 
  theme_bw()
dev.off()


# old plots

png("testing.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = meanlogexp, y = out_spnngp)) + 
  geom_point() + 
  geom_smooth() + 
  theme_bw()
dev.off()

png("testing.png")
ggplot(as.data.frame(rowData(spe_sub)), aes(x = rank_spnngp, y = out_spnngp)) + 
  geom_point() + 
  scale_x_reverse() + 
  theme_bw()
dev.off()


# to do:
# - set tuning parameters more carefully
# - try count-based spNNGP model
# - try squared instead of absolute value
# - try elbow instead of formal significance


