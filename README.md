# Usage

## Prerequisites
- Cluster with Kepler and Prometheus deployed
    - Prometheus must scrape [cAdvisor metrics](https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md) (tested with [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack))
- `kubectl` is correctly configured to manage your target cluster
- Kepler metrics are exported to Promtheus server
- Prometheus server is available at `http://localhost:9090`. Otherwise, set environment variable: `PROM_SERVER`

## Run scalability benchmarks
Run
`./script.sh run_benchmark`

## Plot overhead metrics from benchmark files
1. [Open Jupyter Notebook](plot.ipynb)
2. Assign `result_directories` and `experiment_names` values
    - `result_directories` should be the paths to the directories created by `./script.sh run_benchmark` (e.g. `_output/results/scale-dummy-deployment/2023_10_04_09_47_AM`)
    - `experiment_names` will be the labels used when plotting multiple experiments and should be aligned to match the indexing of `result_directories`
3. Execute `plot_experiments(result_directories, experiment_names)`