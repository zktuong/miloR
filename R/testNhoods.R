#' Perform differential neighbourhood abundance testing
#'
#' This will perform differential neighbourhood abundance testing after cell
#' counting.
#' @param x A \code{\linkS4class{Milo}} object with a non-empty
#' \code{nhoodCounts} slot.
#' @param design A \code{formula} or \code{model.matrix} object describing the
#' experimental design for differential abundance testing. The last component
#' of the formula or last column of the model matrix are by default the test
#' variable. This behaviour can be overridden by setting the \code{model.contrasts}
#' argument
#' @param design.df A \code{data.frame} containing meta-data to which \code{design}
#' refers to
#' @param min.mean A scalar used to threshold neighbourhoods on the minimum
#' average cell counts across samples.
#' @param model.contrasts A string vector that defines the contrasts used to perform
#' DA testing.
#' @param fdr.weighting The spatial FDR weighting scheme to use. Choice from max,
#' neighbour-distance or k-distance (default). If \code{none} is passed no
#' spatial FDR correction is performed and returns a vector of NAs.
#' @param robust If robust=TRUE then this is passed to edgeR and limma which use a robust
#' estimation for the global quasilikihood dispersion distribution. See \code{edgeR} and
#' Phipson et al, 2013 for details.
#' @param norm.method A character scalar, either \code{"logMS"}, \code{"TMM"} or \code{"RLE"}.
#' The \code{"logMS"} method normalises the counts across samples using the log columns sums of
#' the count matrix as a model offset. \code{"TMM"} uses the trimmed mean of M-values normalisation
#' as described in Robinson & Oshlack, 2010, whilst \code{"RLE"} uses the relative log expression
#' method by Anders & Huber, 2010, to compute normalisation factors relative to a reference computed from
#' the geometric mean across samples.  The latter methods provides a degree of robustness against false positives
#' when there are very large compositional differences between samples.
#'
#'
#' @details
#' This function wraps up several steps of differential abundance testing using
#' the \code{edgeR} functions. These could be performed separately for users
#' who want to exercise more contol over their DA testing. By default this
#' function sets the \code{lib.sizes} to the colSums(x), and uses the
#' Quasi-Likelihood F-test in \code{glmQLFTest} for DA testing. FDR correction
#' is performed separately as the default multiple-testing correction is
#' inappropriate for neighbourhoods with overlapping cells.
#'
#' @return A \code{data.frame} of model results, which contain:
#' \describe{
#' \item{\code{logFC}:}{Numeric, the log fold change between conditions, or for
#' an ordered/continous variable the per-unit
#' change in (normalized) cell counts per unit-change in experimental variable.}
#' \item{\code{logCPM}:}{Numeric, the log counts per million (CPM), which equates
#' to the average log normalized cell counts
#' across all samples.}
#' \item{\code{F}:}{Numeric, the F-test statistic from the quali-likelihood F-test
#' implemented in \code{edgeR}.}
#' \item{\code{PValue}:}{Numeric, the unadjusted p-value from the quasi-likelihood F-test.}
#' \item{\code{FDR}:}{Numeric, the Benjamini & Hochberg false discovery weight
#' computed from \code{p.adjust}.}
#' \item{\code{Nhood}:}{Numeric, a unique identifier corresponding to the specific
#' graph neighbourhood.}
#' \item{\code{SpatialFDR}:}{Numeric, the weighted FDR, computed to adjust for spatial
#' graph overlaps between neighbourhoods. For details see \link{graphSpatialFDR}.}
#' }
#'
#' @author Mike Morgan
#'
#' @examples
#' library(SingleCellExperiment)
#' ux.1 <- matrix(rpois(12000, 5), ncol=400)
#' ux.2 <- matrix(rpois(12000, 4), ncol=400)
#' ux <- rbind(ux.1, ux.2)
#' vx <- log2(ux + 1)
#' pca <- prcomp(t(vx))
#'
#' sce <- SingleCellExperiment(assays=list(counts=ux, logcounts=vx),
#'                             reducedDims=SimpleList(PCA=pca$x))
#'
#' milo <- Milo(sce)
#' milo <- buildGraph(milo, k=20, d=10, transposed=TRUE)
#' milo <- makeNhoods(milo, k=20, d=10, prop=0.3)
#' milo <- calcNhoodDistance(milo, d=10)
#'
#' cond <- rep("A", ncol(milo))
#' cond.a <- sample(1:ncol(milo), size=floor(ncol(milo)*0.25))
#' cond.b <- setdiff(1:ncol(milo), cond.a)
#' cond[cond.b] <- "B"
#' meta.df <- data.frame(Condition=cond, Replicate=c(rep("R1", 132), rep("R2", 132), rep("R3", 136)))
#' meta.df$SampID <- paste(meta.df$Condition, meta.df$Replicate, sep="_")
#' milo <- countCells(milo, meta.data=meta.df, samples="SampID")
#'
#' test.meta <- data.frame("Condition"=c(rep("A", 3), rep("B", 3)), "Replicate"=rep(c("R1", "R2", "R3"), 2))
#' test.meta$Sample <- paste(test.meta$Condition, test.meta$Replicate, sep="_")
#' rownames(test.meta) <- test.meta$Sample
#' da.res <- testNhoods(milo, design=~Condition, design.df=test.meta[colnames(nhoodCounts(milo)), ], norm.method="TMM")
#' da.res
#'
#' @name testNhoods
NULL


#' @export
#' @importFrom stats model.matrix
#' @importFrom Matrix colSums rowMeans
#' @importFrom stats dist median
#' @importFrom limma makeContrasts
#' @importFrom edgeR DGEList estimateDisp glmQLFit glmQLFTest topTags calcNormFactors
testNhoods <- function(x, design, design.df,
                       fdr.weighting=c("k-distance", "neighbour-distance", "max", "none"),
                       min.mean=0, model.contrasts=NULL, robust=TRUE,
                       norm.method=c("TMM", "RLE", "logMS")){
    if(is(design, "formula")){
        model <- model.matrix(design, data=design.df)
        rownames(model) <- rownames(design.df)
    } else if(is(design, "matrix")){
        model <- design
        if(nrow(model) != nrow(design.df)){
            stop("Design matrix and model matrix are not the same dimensionality")
        }

        if(any(rownames(model) != rownames(design.df))){
            warning("Design matrix and model matrix dimnames are not the same")
            # check if rownames are a subset of the design.df
            check.names <- any(rownames(model) %in% rownames(design.df))
            if(isTRUE(check.names)){
                rownames(model) <- rownames(design.df)
            } else{
                stop("Design matrix and model matrix rownames are not a subset")
            }
        }
    }

    if(!is(x, "Milo")){
        stop("Unrecognised input type - must be of class Milo")
    } else if(.check_empty(x, "nhoodCounts")){
        stop("Neighbourhood counts missing - please run countCells first")
    }

    if(!any(norm.method %in% c("TMM", "logMS", "RLE"))){
        stop("Normalisation method ", norm.method, " not recognised. Must be either TMM, RLE or logMS")
    }

    subset.counts <- FALSE
    if(ncol(nhoodCounts(x)) != nrow(model)){
        # need to allow for design.df with a subset of samples only
        if(all(rownames(model) %in% colnames(nhoodCounts(x)))){
            message("Design matrix is a strict subset of the nhood counts")
            subset.counts <- TRUE
        } else{
            stop("Design matrix (", nrow(model), ") and nhood counts (",
                 ncol(nhoodCounts(x)), ") are not the same dimension")
        }
    }

    # assume nhoodCounts and model are in the same order
    # cast as DGEList doesn't accept sparse matrices
    # what is the cost of cast a matrix that is already dense vs. testing it's class
    if(min.mean > 0){
        if(isTRUE(subset.counts)){
            keep.nh <- rowMeans(nhoodCounts(x)[, rownames(model)]) >= min.mean
        } else{
            keep.nh <- rowMeans(nhoodCounts(x)) >= min.mean
        }
    } else{
        if(isTRUE(subset.counts)){
            keep.nh <- rep(TRUE, nrow(nhoodCounts(x)[, rownames(model)]))
        }else{
            keep.nh <- rep(TRUE, nrow(nhoodCounts(x)))
        }
    }

    if(isTRUE(subset.counts)){
        keep.samps <- intersect(rownames(model), colnames(nhoodCounts(x)[keep.nh, ]))
    } else{
        keep.samps <- colnames(nhoodCounts(x)[keep.nh, ])
    }

    if(any(colnames(nhoodCounts(x)[keep.nh, keep.samps]) != rownames(model)) & !any(colnames(nhoodCounts(x)[keep.nh, keep.samps]) %in% rownames(model))){
        stop("Sample names in design matrix and nhood counts are not matched.
             Set appropriate rownames in design matrix.")
    } else if(any(colnames(nhoodCounts(x)[keep.nh, keep.samps]) != rownames(model)) & any(colnames(nhoodCounts(x)[keep.nh, keep.samps]) %in% rownames(model))){
        warning("Sample names in design matrix and nhood counts are not matched. Reordering")
        model <- model[colnames(nhoodCounts(x)[keep.nh, keep.samps]), ]
    }

    if(length(norm.method) > 1){
        message("Using TMM normalisation")
        dge <- DGEList(counts=nhoodCounts(x)[keep.nh, keep.samps],
                       lib.size=colSums(nhoodCounts(x)[keep.nh, keep.samps]))
        dge <- calcNormFactors(dge, method="TMM")
    } else if(norm.method %in% c("TMM")){
        message("Using TMM normalisation")
        dge <- DGEList(counts=nhoodCounts(x)[keep.nh, keep.samps],
                       lib.size=colSums(nhoodCounts(x)[keep.nh, keep.samps]))
        dge <- calcNormFactors(dge, method="TMM")
    } else if(norm.method %in% c("RLE")){
        message("Using RLE normalisation")
        dge <- DGEList(counts=nhoodCounts(x)[keep.nh, keep.samps],
                       lib.size=colSums(nhoodCounts(x)[keep.nh, keep.samps]))
        dge <- calcNormFactors(dge, method="RLE")
    }else if(norm.method %in% c("logMS")){
        message("Using logMS normalisation")
        dge <- DGEList(counts=nhoodCounts(x)[keep.nh, keep.samps],
                       lib.size=colSums(nhoodCounts(x)[keep.nh, keep.samps]))
    }

    dge <- estimateDisp(dge, model)
    fit <- glmQLFit(dge, model, robust=robust)
    if(!is.null(model.contrasts)){
        mod.constrast <- makeContrasts(contrasts=model.contrasts, levels=model)
        res <- as.data.frame(topTags(glmQLFTest(fit, contrast=mod.constrast),
                                     sort.by='none', n=Inf))
    } else{
        n.coef <- ncol(model)
        res <- as.data.frame(topTags(glmQLFTest(fit, coef=n.coef), sort.by='none', n=Inf))
    }

    res$Nhood <- as.numeric(rownames(res))
    message("Performing spatial FDR correction with", fdr.weighting[1], " weighting")
    mod.spatialfdr <- graphSpatialFDR(x.nhoods=nhoods(x),
                                      graph=graph(x),
                                      weighting=fdr.weighting,
                                      k=x@.k,
                                      pvalues=res[order(res$Nhood), ]$PValue,
                                      indices=nhoodIndex(x),
                                      distances=nhoodDistances(x),
                                      reduced.dimensions=reducedDim(x, "PCA"))

    res$SpatialFDR[order(res$Nhood)] <- mod.spatialfdr
    res
}
