# zulake: Inspect and Read 'Delta Lake' Tables

Opens a 'Delta Lake' table where it is stored, on 'Azure Data Lake
Storage Gen2', 'Azure Blob Storage' or local disk, and returns what the
table's own log records as data frames: its versions and commits, the
files of each version with their partition values, statistics and
deletion vectors, its schema, protocol and properties, and the changes
between two versions. Reads the table's data too, pruning files by
partition values and statistics before downloading any of them. The log
is replayed in R, following the 'Delta Lake' protocol
<https://github.com/delta-io/delta/blob/master/PROTOCOL.md>.

## See also

Useful links:

- <https://pedrobtz.github.io/zulake/>

- <https://github.com/pedrobtz/zulake>

- Report bugs at <https://github.com/pedrobtz/zulake/issues>

## Author

**Maintainer**: Pedro Baltazar <pedrobtz@gmail.com> \[copyright holder\]

Authors:

- Pedro Baltazar <pedrobtz@gmail.com> \[copyright holder\]
