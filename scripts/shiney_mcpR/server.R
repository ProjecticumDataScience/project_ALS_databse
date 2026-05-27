# ════════════════════════════════════════════════════════════════════════════
# rvatData MCP Server — R + DBI
# ════════════════════════════════════════════════════════════════════════════

library(DBI)
library(RSQLite)
library(plumber)
library(jsonlite)

DB_PATH <- path.expand(
  Sys.getenv(
    "RVAT_GDB_PATH",
    "~/project_ALS_databse/rvatData.sqlite"
  )
)

# ───────────────────────────────────────────────────────────────────────────
# Database connectie
# ───────────────────────────────────────────────────────────────────────────

get_con <- function() {
  
  dbConnect(
    SQLite(),
    DB_PATH,
    flags = SQLITE_RO
  )
}

query_db <- function(sql,
                     params = list(),
                     max_rows = 500) {
  
  if (!grepl("^\\s*SELECT", sql, ignore.case = TRUE)) {
    stop("Alleen SELECT queries toegestaan.")
  }
  
  con <- get_con()
  
  on.exit(dbDisconnect(con))
  
  result <- dbGetQuery(
    con,
    sql,
    params = params
  )
  
  head(result, max_rows)
}

# ════════════════════════════════════════════════════════════════════════════
# API ENDPOINTS
# ════════════════════════════════════════════════════════════════════════════

#* Database samenvatting
#* @get /summarize_database
function() {
  
  con <- get_con()
  
  on.exit(dbDisconnect(con))
  
  scalar <- function(sql) {
    dbGetQuery(con, sql)[1,1]
  }
  
  list(
    totaal_varianten = scalar(
      "SELECT COUNT(*) FROM varInfo_synthetic"
    ),
    
    unieke_genen = scalar(
      "SELECT COUNT(DISTINCT gene_name)
       FROM varInfo_synthetic"
    ),
    
    high_impact = scalar(
      "SELECT COUNT(*)
       FROM varInfo_synthetic
       WHERE HighImpact = 1"
    ),
    
    gemiddelde_AF = scalar(
      "SELECT ROUND(AVG(AF), 6)
       FROM varInfo_synthetic"
    )
  )
}

#* Varianten per gen
#* @post /get_variants_by_gene
function(gene = "NEK1",
         limit = 500) {
  
  query_db(
    paste0(
      "SELECT *
       FROM varInfo_synthetic
       WHERE gene_name = ?
       LIMIT ",
      as.integer(limit)
    ),
    params = list(gene)
  )
}

#* Top genen
#* @post /count_variants_by_gene
function(top_n = 20) {
  
  query_db(
    paste0(
      "SELECT gene_name,
              COUNT(*) AS n
       FROM varInfo_synthetic
       GROUP BY gene_name
       ORDER BY n DESC
       LIMIT ",
      as.integer(top_n)
    )
  )
}

#* Impact filtering
#* @post /get_variants_by_impact
function(impact = "HIGH",
         limit = 100) {
  
  impact_col <- switch(
    toupper(impact),
    HIGH      = "HighImpact",
    MODERATE  = "ModerateImpact",
    stop("Impact moet HIGH of MODERATE zijn.")
  )
  
  query_db(
    paste0(
      "SELECT *
       FROM varInfo_synthetic
       WHERE ",
      impact_col,
      " = 1
       LIMIT ",
      as.integer(limit)
    )
  )
}

#* Schadelijke varianten
#* @post /get_deleterious_variants
function(predictor = "SIFT",
         limit = 100) {
  
  sql <- if (toupper(predictor) == "SIFT") {
    
    paste0(
      "SELECT *
       FROM varInfo_synthetic
       WHERE SIFT = 'D'
       LIMIT ",
      as.integer(limit)
    )
    
  } else {
    
    paste0(
      "SELECT *
       FROM varInfo_synthetic
       WHERE PolyPhen = 'D'
       LIMIT ",
      as.integer(limit)
    )
  }
  
  query_db(sql)
}

#* Dragers per gen
#* @post /get_carriers_by_gene
function(gene = "NEK1",
         group = "ALS") {
  
  cols <- if (toupper(group) == "ALS") {
    
    paste0("ALS_", 1:5)
    
  } else {
    
    paste0("Control_", 1:5)
  }
  
  filter_sql <- paste0(cols, " > 0", collapse = " OR ")
  
  query_db(
    paste0(
      "SELECT *
       FROM varInfo_synthetic
       WHERE gene_name = ?
         AND (",
      filter_sql,
      ")"
    ),
    params = list(gene)
  )
}

#* Vrije query
#* @post /run_query
function(sql = "") {
  
  query_db(sql)
}

# ───────────────────────────────────────────────────────────────────────────
# Start server
# ───────────────────────────────────────────────────────────────────────────



pr$run(
  host = "0.0.0.0",
  port = 8000
)