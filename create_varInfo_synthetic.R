## Load packages
library(rvat)
library(rvatData)
library(DBI)

## Load example gdb
gdb <- gdb(rvat_example("rvatData.gdb"))

## Inspect the tables in the gdb
dbListTables(gdb)
dbGetQuery(gdb, "SELECT * FROM pheno LIMIT 5")
dbGetQuery(gdb, "SELECT * FROM var LIMIT 5")
dbGetQuery(gdb, "SELECT * FROM varInfo LIMIT 5")

##------------------------------------------------------- We are going add a few column with synthethic data that resembles the real data strucutre -------------------------------------------------------##
## load the varInfo table into R. We will use this as base table
vi <- dbGetQuery(gdb, "SELECT * FROM varInfo")

## set seed for reproducibility
set.seed(123)

## add 10 genotype columns (value 0 = homozygous for the reference allele, 1 = heterozygous, 2 = homozygous for the alternative allele)
n_rows <- nrow(vi)

geno_als <- replicate(5, sample(0:2, n_rows, replace = TRUE))
colnames(geno_als) <- paste0("ALS_", 1:5)

geno_control <- replicate(5, sample(0:2, n_rows, replace = TRUE))
colnames(geno_control) <- paste0("Control_", 1:5)

## add the new columns to the varInfo table
vi_updated <- cbind(vi, geno_als, geno_control)

## Inspect if the new columns are added correctly
head(vi_updated)

## upload to the gdb
dbWriteTable(gdb, "varInfo_synthetic", vi_updated, overwrite = TRUE)

## check if the table is in the database and looks correct
dbListTables(gdb)
dbGetQuery(gdb, "SELECT * FROM varInfo_synthetic LIMIT 5")

## close the connection
dbDisconnect(gdb)
