# Kernel SHAP algorithm for a single row x
# If exact, a single call to predict() is necessary.
# If sampling is involved, we need at least two additional calls to predict().
kernelshap_one <- function(x, v1, object, pred_fun, feature_names, bg_w, exact, deg, 
                           paired, m, tol, max_iter, v0, precalc, ...) {
  p <- length(feature_names)

  # Calculate A_exact and b_exact
  if (exact || deg >= 1L) {
    A_exact <- precalc[["A"]]                                     #  (p x p)
    bg_X_exact <- precalc[["bg_X_exact"]]                         #  (m_ex*n_bg x p)
    Z <- precalc[["Z"]]                                           #  (m_ex x p)
    m_exact <- nrow(Z)
    v0_m_exact <- v0[rep(1L, m_exact), , drop = FALSE]            #  (m_ex x K)
    
    # Most expensive part
    vz <- get_vz(                                                 #  (m_ex x K)
      X = x[rep(1L, times = nrow(bg_X_exact)), , drop = FALSE],   #  (m_ex*n_bg x p)
      bg = bg_X_exact,                                            #  (m_ex*n_bg x p)
      Z = Z,                                                      #  (m_ex x p)
      object = object, 
      pred_fun = pred_fun,
      w = bg_w, 
      ...
    )
    # Note: w is correctly replicated along columns of (vz - v0_m_exact)
    b_exact <- crossprod(Z, precalc[["w"]] * (vz - v0_m_exact))   #  (p x K)
    
    # Some of the hybrid cases are exact as well
    if (exact || trunc(p / 2) == deg) {
      beta <- solver(A_exact, b_exact, constraint = v1 - v0)      #  (p x K)
      return(list(beta = beta, sigma = 0 * beta, n_iter = 1L, converged = TRUE))  
    }
  } 
  
  # Iterative sampling part, always using A_exact and b_exact to fill up the weights
  bg_X_m <- precalc[["bg_X_m"]]                                   #  (m*n_bg x p)
  X <- x[rep(1L, times = nrow(bg_X_m)), , drop = FALSE]           #  (m*n_bg x p)
  v0_m <- v0[rep(1L, m), , drop = FALSE]                          #  (m x K)

  est_m = list()
  converged <- FALSE
  n_iter <- 0L
  A_sum <- matrix(                                                #  (p x p)
    0, nrow = p, ncol = p, dimnames = list(feature_names, feature_names)
  )
  b_sum <- matrix(                                                #  (p x K)
    0, nrow = p, ncol = ncol(v0), dimnames = list(feature_names, colnames(v1))
  )      
  if (deg == 0L) {
    A_exact <- A_sum
    b_exact <- b_sum
  }
  
  while(!isTRUE(converged) && n_iter < max_iter) {
    n_iter <- n_iter + 1L
    input <- input_sampling(
      p = p, m = m, deg = deg, paired = paired, feature_names = feature_names
    )
    Z <- input[["Z"]]
      
    # Expensive                                                              #  (m x K)
    vz <- get_vz(
      X = X, bg = bg_X_m, Z = Z, object = object, pred_fun = pred_fun, w = bg_w, ...
    )
    
    # The sum of weights of A_exact and input[["A"]] is 1, same for b
    A_temp <- A_exact + input[["A"]]                                         #  (p x p)
    b_temp <- b_exact + crossprod(Z, input[["w"]] * (vz - v0_m))             #  (p x K)
    A_sum <- A_sum + A_temp                                                  #  (p x p)
    b_sum <- b_sum + b_temp                                                  #  (p x K)
    
    # Least-squares with constraint that beta_1 + ... + beta_p = v_1 - v_0. 
    # The additional constraint beta_0 = v_0 is dealt via offset   
    est_m[[n_iter]] <- solver(A_temp, b_temp, constraint = v1 - v0)          #  (p x K)

    # Covariance calculation would fail in the first iteration
    if (n_iter >= 2L) {
      beta_n <- solver(A_sum / n_iter, b_sum / n_iter, constraint = v1 - v0) #  (p x K)
      sigma_n <- get_sigma(est_m, iter = n_iter)                             #  (p x K)
      converged <- all(conv_crit(sigma_n, beta_n) < tol)
    }
  }
  list(beta = beta_n, sigma = sigma_n, n_iter = n_iter, converged = converged)
}

# Regression coefficients given sum(beta) = constraint
# A: (p x p), b: (p x k), constraint: (1 x K)
solver <- function(A, b, constraint) {
  p <- ncol(A)
  Ainv <- ginv(A)
  dimnames(Ainv) <- dimnames(A)
  s <- (matrix(colSums(Ainv %*% b), nrow = 1L) - constraint) / sum(Ainv)     #  (1 x K)
  Ainv %*% (b - s[rep(1L, p), , drop = FALSE])                               #  (p x K)
}

ginv <- function (X, tol = sqrt(.Machine$double.eps)) {
  ##
  ## Based on an original version in package MASS 7.3.56
  ## (with permission)
  ##
  if (length(dim(X)) > 2L || !(is.numeric(X) || is.complex(X))) {
    stop("'X' must be a numeric or complex matrix")
  }
  if (!is.matrix(X)) {
    X <- as.matrix(X)
  }
  Xsvd <- svd(X)
  if (is.complex(X)) {
    Xsvd$u <- Conj(Xsvd$u)
  }
  Positive <- Xsvd$d > max(tol * Xsvd$d[1L], 0)
  if (all(Positive)) {
    Xsvd$v %*% (1 / Xsvd$d * t(Xsvd$u))
  } else if (!any(Positive)) {
    array(0, dim(X)[2L:1L])
  } else {
    Xsvd$v[, Positive, drop = FALSE] %*% 
      ((1 / Xsvd$d[Positive]) * t(Xsvd$u[, Positive, drop = FALSE]))
  }
}

#' Masker
#'
#' Internal function. 
#' For each on-off vector (rows in `Z`), the (weighted) average prediction is returned.
#'
#' @noRd
#' @keywords internal
#'
#' @inheritParams kernelshap
#' @param X Row to be explained stacked m*n_bg times.
#' @param bg Background data stacked m times.
#' @param Z A (m x p) matrix with on-off values.
#' @param w A vector with case weights (of the same length as the unstacked
#'   background data).
#' @returns A (m x K) matrix with vz values.
get_vz <- function(X, bg, Z, object, pred_fun, w, ...) {
  m <- nrow(Z)
  not_Z <- !Z
  n_bg <- nrow(bg) / m   # because bg was replicated m times
  
  # Replicate not_Z, so that X, bg, not_Z are all of dimension (m*n_bg x p)
  g <- rep(seq_len(m), each = n_bg)
  not_Z <- not_Z[g, , drop = FALSE]
  
  if (is.matrix(X)) {
    # Remember that columns of X and bg are perfectly aligned in this case
    X[not_Z] <- bg[not_Z]
  } else {
    for (v in colnames(Z)) {
      s <- not_Z[, v]
      X[[v]][s] <- bg[[v]][s]
    }
  }
  preds <- align_pred(pred_fun(object, X, ...))
  
  # Aggregate
  if (is.null(w)) {
    return(rowsum(preds, group = g, reorder = FALSE) / n_bg)
  }
  # w is recycled over rows and columns
  rowsum(preds * w, group = g, reorder = FALSE) / sum(w)
}

#' Weighted Version of colMeans()
#' 
#' Internal function used to calculate column-wise weighted means.
#' 
#' @noRd
#' @keywords internal
#' 
#' @param x A matrix-like object.
#' @param w Optional case weights.
#' @returns A (1 x ncol(x)) matrix of column means.
weighted_colMeans <- function(x, w = NULL, ...) {
  if (NCOL(x) == 1L && is.null(w)) {
    return(matrix(mean(x)))
  }
  if (!is.matrix(x)) {
    x <- as.matrix(x)
  }
  rbind(if (is.null(w)) colMeans(x) else colSums(x * w) / sum(w))
}

#' Combine Matrices
#'
#' Binds list of matrices along new first axis.
#'
#' @noRd
#' @keywords internal
#'
#' @param a List of n (p x K) matrices.
#' @returns A (n x p x K) array.
abind1 <- function(a) {
  out <- array(
    dim = c(length(a), dim(a[[1L]])), 
    dimnames = c(list(NULL), dimnames(a[[1L]]))
  )
  for (i in seq_along(a)) {
    out[i, , ] <- a[[i]]
  }
  out
}

#' Reorganize List
#'
#' Internal function that turns list of n (p x K) matrices into list of K (n x p) 
#' matrices. Reduce if K = 1.
#'
#' @noRd
#' @keywords internal
#'
#' @param alist List of n (p x K) matrices.
#' @returns List of K (n x p) matrices.
reorganize_list <- function(alist) {
  if (!is.list(alist)) {
    stop("alist must be a list")
  }
  out <- asplit(abind1(alist), MARGIN = 3L)
  if (length(out) == 1L) {
    return(as.matrix(out[[1L]]))
  }
  lapply(out, as.matrix)
}

#' Aligns Predictions
#'
#' Turns predictions into matrix. Originally implemented in {hstats}.
#'
#' @noRd
#' @keywords internal
#'
#' @param x Object representing model predictions.
#' @returns Like `x`, but converted to matrix.
align_pred <- function(x) {
  if (!is.matrix(x)) {
    x <- as.matrix(x)
  }
  if (!is.numeric(x)) {
    stop("Predictions must be numeric")
  }
  x
}

#' Head of List Elements
#'
#' Internal function that returns the top n rows of each element in the input list.
#'
#' @noRd
#' @keywords internal
#'
#' @param x A list or a matrix-like.
#' @param n Number of rows to show.
#' @returns List of first rows of each element in the input.
head_list <- function(x, n = 6L) {
  if (!is.list(x)) utils::head(x, n) else lapply(x, utils::head, n)
}

# Summarize details about the chosen algorithm (exact, hybrid, sampling)
summarize_strategy <- function(p, exact, deg) {
  if (exact || trunc(p / 2) == deg) {
    txt <- "Exact Kernel SHAP values"
    if (!exact) {
      txt <- paste(txt, "by the hybrid approach")
    }
    return(txt)
  }
  if (deg == 0L) {
    return("Kernel SHAP values by iterative sampling")
  } 
  paste("Kernel SHAP values by the hybrid strategy of degree", deg)
}

# Kernel weights normalized to a non-empty subset S of {1, ..., p-1}
kernel_weights <- function(p, S = seq_len(p - 1L)) {
  probs <- (p - 1L) / (choose(p, S) * S * (p - S))
  probs / sum(probs)
}

#' mlr3 Helper
#' 
#' Returns the prediction function of a mlr3 Learner.
#' 
#' @noRd
#' @keywords internal
#' 
#' @param object Learner object.
#' @param X Dataframe like object.
#' 
#' @returns A function.
mlr3_pred_fun <- function(object, X) {
  if ("classif" %in% object$task_type) {
    # Check if probabilities are available
    test_pred <- object$predict_newdata(utils::head(X))
    if ("prob" %in% test_pred$predict_types) {
      return(function(m, X) m$predict_newdata(X)$prob)
    } else {
      stop("Set lrn(..., predict_type = 'prob') to allow for probabilistic classification.")
    }
  }
  function(m, X) m$predict_newdata(X)$response
}
