# Host context

Captured on 2026-10-01 before or during database startup. These are snapshots, not continuous workload monitoring.

- Host: MacBook Air, Apple M4, 10 CPU cores (4 performance, 6 efficiency), 16 GB RAM.
- Host OS: macOS 27.0, arm64; Python 3.14.3.
- Host storage: internal Apple AP0512Z NVMe SSD, nominal 500 GB; approximately 49 GiB free on the workspace filesystem before the run.
- Database storage: per-run Docker named volumes in the Docker Desktop Linux VM; no `tmpfs` configuration.
- Docker Desktop: 4.88.1 (237512); client/server 29.7.2; Compose v5.4.0.
- Docker VM: Linux/aarch64, kernel 7.0.12-linuxkit, 10 CPUs, 8,319,504,384 bytes (7.75 GiB) memory reported by `docker info`.
- No per-container CPU or memory limits are set by this lab. PostgreSQL shared buffers and the InnoDB buffer pool are each configured to 128 MiB; these are not total engine memory limits.
- Host load averages before the run: 4.21, 2.87, 2.70 (1, 5, 15 minutes).
- Four unrelated PostgreSQL 18 containers were already running. A `docker stats --no-stream` snapshot showed CPU usage of 0.00%, 0.03%, 0.01%, and 1.51%, and memory usage of 31.14, 30.45, 30.93, and 125.1 MiB respectively.
- This is a shared development machine. Host activity and other containers were not suspended; background load was not controlled or continuously measured.

Inspection commands:

```bash
system_profiler SPHardwareDataType SPNVMeDataType -json
docker version
docker compose version
docker info
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
docker stats --no-stream
uptime
df -h .
```

Hardware serial numbers and identifiers are omitted. The runner's `environment.json` records the exact OS, Python version, Docker information, and resolved Compose configuration.

## Startup troubleshooting

The first attempt used `./run.sh 100000 result/run-2026-10-01-100k` from `benchmark/`. Docker Hub returned `EOF` while resolving the image manifests; individual pulls of `postgres:17` and `mysql:8.4` also failed. No database measurements were produced by that attempt. Its generated SQL and diagnostics remain in the ignored local directory.

The alternate download source is Docker's official publisher namespace on Amazon ECR Public, using `public.ecr.aws/docker/library/postgres:17` and `public.ecr.aws/docker/library/mysql:8.4`. See [AWS's announcement of Docker Official Images on ECR Public](https://aws.amazon.com/blogs/containers/docker-official-images-now-available-on-amazon-elastic-container-registry-public/). The report records the actual image digests used rather than assuming tags from different registries resolve identically.
