source(file.path(Sys.getenv("W"), "common.R"))
for (name in c("zl-partitioned", "delta-2.2.0-partitioned-types", "zl-inf-partitions", "delta-0.8.0-null-partition", "zl-orders", "table_with_edge_timestamps", "zl-types")) {
  tbl <- lake_open(file.path(FX, name)); cat("==", name, "\n"); print(lake_schema(tbl)[, 1:4]); print(lake_partitions(tbl)); 
}
