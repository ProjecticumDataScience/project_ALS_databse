## MAKE SURE CREATE_VARINFO_SYNTHETIC.R HAS BEEN RAN
## ALSO RUN THE DATA_DESCRIPTION <- AND EXTRA_INSTRUCTIONS <- FROM ANY UPDATED AUTOSCRIPT

library(R6)
library(DBI)

MultiTableSource <- R6Class(
  "MultiTableSource",
  inherit = querychat:::DataSource,
  
  public = list(
    
    initialize = function(conn, table_names) {
      
      # validate connection
      if (!inherits(conn, "DBIConnection")) {
        cli::cli_abort("{.arg conn} must be a {.cls DBIConnection}")
      }
      
      # validate all tables exist
      for (tbl in table_names) {
        if (!DBI::dbExistsTable(conn, tbl)) {
          cli::cli_abort("Table {.val {tbl}} not found in database")
        }
      }
      
      private$conn        <- conn
      private$table_names <- table_names
      
      # first table is the primary display table —
      # this is what get_data() returns and what
      # test_query(require_all_columns = TRUE) validates against
      self$table_name <- table_names[[1]]
      
      # store column names of primary table for test_query
      private$colnames <- colnames(
        DBI::dbGetQuery(
          conn,
          sprintf("SELECT * FROM %s LIMIT 0",
                  DBI::dbQuoteIdentifier(conn, table_names[[1]]))
        )
      )
    },
    
    get_db_type = function() {
      "SQLite"
    },
    
    # call get_schema_impl once per table and concatenate —
    # this is what gets injected into the LLM system prompt
    get_schema = function(categorical_threshold = 20) {
      schemas <- lapply(private$table_names, function(tbl) {
        querychat:::get_schema_impl(
          conn                 = private$conn,
          table_name           = tbl,
          categorical_threshold = categorical_threshold
        )
      })
      paste(schemas, collapse = "\n\n")
    },
    
    # if query is null/empty fall back to SELECT * on primary table
    execute_query = function(query) {
      if (is.null(query) || !nzchar(query)) {
        query <- paste0(
          "SELECT * FROM ",
          DBI::dbQuoteIdentifier(private$conn, self$table_name)
        )
      }
      DBI::dbGetQuery(private$conn, query)
    },
    
    # require_all_columns = TRUE is only used for dashboard update queries,
    # which must return all columns of the primary table.
    # for multi-table JOIN queries (question answering) it will be FALSE.
    test_query = function(query, require_all_columns = FALSE) {
      rs <- DBI::dbSendQuery(private$conn, query)
      df <- DBI::dbFetch(rs, n = 1)
      DBI::dbClearResult(rs)
      
      if (require_all_columns) {
        result_columns  <- names(df)
        missing_columns <- setdiff(private$colnames, result_columns)
        if (length(missing_columns) > 0) {
          missing_list <- paste0("'", missing_columns, "'", collapse = ", ")
          cli::cli_abort(
            c("Query result missing required columns: {missing_list}",
              i = "Dashboard update queries must return all columns of the primary table ({self$table_name})."),
            class = "querychat_missing_columns_error"
          )
        }
      }
      df
    },
    
    # returns the primary display table for the Shiny data table
    get_data = function() {
      DBI::dbReadTable(private$conn, self$table_name)
    },
    
    cleanup = function() invisible(NULL)
  ),
  
  private = list(
    conn        = NULL,
    table_names = NULL
  )
)

multi_src <- MultiTableSource$new(
  conn        = gdb,
  table_names = c("varInfo_synthetic", "pheno")
)

cat(multi_src$get_schema())

custom_prompt_path <- "~/project_ALS_databse/custom_prompt.md"

qc_multi <- QueryChat$new(
  data_source        = multi_src,
  client             = ollama_client,
  data_description   = data_description,
  extra_instructions = extra_instructions,
  id                 = "querychat_multi",
  prompt_template    = custom_prompt_path
)

qc_multi$console() # works with both pheno and varInfo
