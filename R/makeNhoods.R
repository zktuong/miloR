#' Define neighbourhoods on a graph (fast)
#'
#' This function randomly samples vertcies on a graph to define neighbourhoods.
#' These are then refined by computing the median profile for the neighbourhood
#' in reduced dimensional space and selecting the nearest vertex to this
#' position. Thus, multiple neighbourhoods may be collapsed down together to
#' prevent over-sampling the graph space.
#' @param x A \code{\linkS4class{Milo}} object with a non-empty \code{graph}
#' slot. Alternatively an \code{igraph} object on which neighbourhoods will
#' be defined.
#' @param prop A double scalar that defines what proportion of graph vertices
#' to randomly sample. Must be 0 < prop < 1.
#' @param k An integer scalar - the same k used to construct the input graph.
#' @param d The number of dimensions to use if the input is a matrix of cells
#' X reduced dimensions.
#' @param reduced_dims If x is an \code{\linkS4class{Milo}} object, a character indicating the name of the \code{reducedDim} slot in the
#' \code{\linkS4class{Milo}} object to use as (default: 'PCA'). If x is an \code{igraph} object, a
#' matrix of vertices X reduced dimensions.
#' @param refined A logical scalar that determines the sampling behaviour, default=TRUE implements the refined sampling scheme.
#'
#' @details
#' This function randomly samples graph vertices, then refines them to collapse
#' down the number of neighbourhoods to be tested. The refinement behaviour can
#' be turned off by setting \code{refine=FALSE}, however, we do not recommend
#' this as neighbourhoods will contain a lot of redundancy and lead to an
#' unncecessarily larger multiple-testing burden.
#'
#' @return A \code{\linkS4class{Milo}} object containing a list of vertices and
#' the indices of vertices that constitute the neighbourhoods in the
#' isIndex slot. If the input is a \code{igraph} object then the output
#' is a list of vertices and the indices of vertices that constitute the
#' neighbourhoods.
#'
#' @author
#' Emma Dann, Mike Morgan
#'
#' @examples
#'
#' require(igraph)
#' m <- matrix(rnorm(100000), ncol=100)
#' milo <- buildGraph(m, d=10)
#'
#' milo <- makeNhoods(milo, prop=0.1)
#' milo
#'
#' @export
#' @rdname makeNhoods
#' @importFrom BiocNeighbors findKNN
#' @importFrom igraph neighbors as_ids
#' @importFrom stats setNames
makeNhoods <- function(x, prop=0.1, k=21, d=30, refined=TRUE, reduced_dims="PCA") {
    if(is(x, "Milo")){
        message("Checking valid object")
        # check that a graph has been built
        if(!.valid_graph(graph(x))){
            stop("Not a valid Milo object - graph is missing. Please run buildGraph() first.")
        }
        graph <- graph(x)
        X_reduced_dims  <- reducedDim(x, reduced_dims)
        if (d > ncol(X_reduced_dims)) {
            warning("Specified d is higher than the total number of dimensions in reducedDim(x, reduced_dims). Falling back to using",
                    ncol(X_reduced_dims),"dimensions\n")
            d <- ncol(X_reduced_dims)
        }
        X_reduced_dims  <- X_reduced_dims[,seq_len(d)]
    } else if(is(x, "igraph")){
        if(!is.matrix(reduced_dims) & isTRUE(refined)){
            stop("No reduced dimensions matrix provided - required for refined sampling")
        }
        graph <- x
        X_reduced_dims <- reduced_dims
    } else{
        stop("Data format: ", class(x), " not recognised. Should be Milo or igraph")
    }
    random_vertices <- .sample_vertices(graph, prop, return.vertices = TRUE)

    if (isFALSE(refined)) {
        sampled_vertices <- random_vertices
    } else if (isTRUE(refined)) {
        sampled_vertices <- .refined_sampling(random_vertices, X_reduced_dims, k)
        }

    sampled_vertices <- unique(sampled_vertices)

    nh_mat <- Matrix(data = 0, nrow=ncol(x), ncol=length(sampled_vertices), sparse = TRUE)
    # Is there an alternative to using a for loop to populate the sparseMatrix here?
    for (X in seq_len(length(sampled_vertices))){
        nh_mat[as_ids(neighbors(graph, v = sampled_vertices[X])), X] <- 1
    }

    # need to add the index cells.
    colnames(nh_mat) <- as.character(sampled_vertices)
    if(is(x, "Milo")){
        nhoodIndex(x) <- as(sampled_vertices, "list")
        nhoods(x) <- nh_mat
        return(x)
    } else {
        return(nh_mat)
    }
}

#' @importFrom BiocNeighbors findKNN
#' @importFrom matrixStats colMedians
.refined_sampling <- function(random_vertices, X_reduced_dims, k){
    vertex.knn <-
        findKNN(
            X = X_reduced_dims,
            k = k,
            subset = as.vector(random_vertices),
            get.index = TRUE,
            get.distance = FALSE
        )

    nh_reduced_dims <- t(apply(vertex.knn$index, 1, function(x) colMedians(X_reduced_dims[x,])))

    # this function fails if rownames are not set
    if(is.null(rownames(X_reduced_dims))){
        warning("Rownames not set on reducedDims - setting to row indices")
        rownames(X_reduced_dims) <- as.character(seq_len(nrow(X_reduced_dims)))
    }

    colnames(nh_reduced_dims) <- colnames(X_reduced_dims)
    rownames(nh_reduced_dims) <- paste0('nh_', seq_len(nrow(nh_reduced_dims)))

    ## Search nearest cell to average profile
    # I have to do this trick because as far as I know there is no fast function to
    # search for NN between 2 distinct sets of points (here I'd like to search NNs of
    # nh_reduced_dims points among X_reduced_dims points). Suggestions are welcome
    all_reduced_dims <- rbind(nh_reduced_dims, X_reduced_dims)
    nn_mat <- findKNN(all_reduced_dims,
                      k = nrow(nh_reduced_dims) + 1,
                      subset = rownames(nh_reduced_dims))[["index"]]
    ## Look for first NN that is not another nhood
    nh_ixs <- seq_len(nrow(nh_reduced_dims))
    i = 1
    sampled_vertices <- rep(0, nrow(nn_mat))
    while (any(sampled_vertices <= max(nh_ixs))) {
        update_ix <- which(sampled_vertices <= max(nh_ixs))
        sampled_vertices[update_ix] <- nn_mat[update_ix, i]
        i <- i + 1
    }
    ## Reset indexes
    sampled_vertices <- sampled_vertices - max(nh_ixs)
    return(sampled_vertices)
}

#' @importFrom igraph is_igraph
.valid_graph <- function(x){
    # check for a valid graph
    if(isTRUE(is_igraph(x))){
        TRUE
    } else{
        FALSE
    }
}

#' @import igraph
.sample_vertices <- function(graph, prop, return.vertices=FALSE){
    # define a set of vertices and neihbourhood centers - extract the neihbourhoods of these cells
    random.vertices <- sample(V(graph), size=floor(prop*length(V(graph))))
    if(isTRUE(return.vertices)){
        return(random.vertices)
    } else{
        message("Finding neighbours of sampled vertices")
        vertex.list <- sapply(seq_len(length(random.vertices)), FUN=function(X) neighbors(graph, v=random.vertices[X]))
        return(list(random.vertices, vertex.list))
    }
}


