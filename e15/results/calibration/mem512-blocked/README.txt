mem512 sbx N=1 seed 1 at a1954f6 (driver 297c8e8a). Does NOT hold: condition 3, median pace +19.3%.
Every scanning-class call ran ~1.4-1.8 s over plan: the 512 MiB scan (cat data.bin) is executed but is
not part of the call's planned duration, so pace = observed / planned - 1 counts the scan as slowdown.
The scan is served from host page cache (disk_read_mbs ~0 in-window, page cache ~11.9 GiB): ~1.6 s is
the guest reading 512 MiB through virtio-blk, not the volume (130.5 MB/s would be ~4.1 s).
