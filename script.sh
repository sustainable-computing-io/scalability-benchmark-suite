#! /bin/bash
set -e
set -o pipefail

export RESULTS_DIR=${RESULTS_DIR:-'./_output/results/'}
export EXPERIMENT_CMD=${EXPERIMENT_CMD:-'./script.sh scale_dummy_deployment'}
export EXPERIMENT_DIR_NAME=${EXPERIMENT_DIR_NAME:-'scale-dummy-deployment'}
export FIRST=${FIRST:-0}
export LAST=${LAST:-40}
export INCREMENT=${INCREMENT:-10}
export INCREMENT_INTERVAL=${INCREMENT_INTERVAL:-1200}
export PROM_SERVER=${PROM_SERVER:-http://localhost:9090}
export KEPLER_LABEL_MATCHER=${KEPLER_LABEL_MATCHER:-'pod=~"kepler-exporter.*"'}
export PROMETHUES_LABEL_MATCHER=${PROMETHUES_LABEL_MATCHER:-'pod=~"prometheus.*"'}

function prepare_output_dir(){
    # Prepare output CSV header
    export OUTPUT_DIR=${RESULTS_DIR}${EXPERIMENT_DIR_NAME}/$(date -d @${START} +"%Y_%m_%d_%I_%M_%p")/
    mkdir -p $OUTPUT_DIR
    export TIMESTAMP_OUTPUT_FILE=${OUTPUT_DIR}timestamps.csv
    echo "Replicas,Start time,End time" > $TIMESTAMP_OUTPUT_FILE
}

function validate_cluster(){
    set +e
    curl -s -g "${PROM_SERVER}/api/v1/query?query=kepler_container_package_joules_total[5s]" | jq '.data.result[].values' --exit-status > /dev/null
    EXIT_STATUS=$?
    if [ $EXIT_STATUS -ne 0 ]; then
        if [ $EXIT_STATUS -eq 7 ]; then
            echo "Error: Could not reach Prometheus server at ${PROM_SERVER}"
            echo 'Help: If not using a ClusterIP/NodePort service to expose Prometheus ensure you forward the port. e.g. `kubectl --insecure-skip-tls-verify -n monitoring port-forward service/kube-prom-stack-prometheus-prometheus 9090:9090`'
            echo 'Help: Rerun with `PROM_SERVER=[your Prometheus url] ./script.sh`'
        elif [ $EXIT_STATUS -eq 4 ]; then
            echo "Error: Prometheus is not scraping Kepler metrics"
            echo "Help: https://github.com/sustainable-computing-io/kepler/issues/767#issuecomment-1717990301"
        fi
        exit $EXIT_STATUS
    fi
    set -e
}

function scale_dummy_deployment(){
    kubectl apply -f dummy-container-deployment.yaml
    # Wait for pods to delete if a deployment already exists
    kubectl wait --for=delete pod -l type=dummy --timeout 5m

    echo "Replicas,Start time,End time" > $TIMESTAMP_OUTPUT_FILE

    for REPLICAS in `seq $FIRST $INCREMENT $LAST`
    do
        kubectl scale deployment dummy-container-deployment --replicas=$REPLICAS

        # Wait for containers to be ready and mark start time with this replica count
        kubectl rollout status deployment dummy-container-deployment
        echo -n "${REPLICAS},$(date +%s)," >> $TIMESTAMP_OUTPUT_FILE

        # Allow Prometheus to collect overhead measurements for 20 minutes
        sleep $INCREMENT_INTERVAL

        # Mark end time with this replica count
        echo "$(date +%s)" >> $TIMESTAMP_OUTPUT_FILE
    done

    kubectl delete deployment dummy-container-deployment
}

function save_overhead_data(){
    QUERIES=(
        "sum(rate(container_cpu_usage_seconds_total{${KEPLER_LABEL_MATCHER}}[2m])) by (pod)" # Kepler cpu
        "sum(rate(container_cpu_usage_seconds_total{${PROMETHUES_LABEL_MATCHER}}[2m])) by (pod)" # Prometheus cpu
        "sum(container_memory_usage_bytes{${KEPLER_LABEL_MATCHER}}) by (pod)" # Kepler memory
        "sum(container_memory_usage_bytes{${PROMETHUES_LABEL_MATCHER}}) by (pod)" # Prometheus memory
        "sum(rate(container_network_receive_bytes_total{${KEPLER_LABEL_MATCHER}}[2m])) by (pod)" # Kepler network receive
        "sum(rate(container_network_receive_bytes_total{${PROMETHUES_LABEL_MATCHER}}[2m])) by (pod)" # Prometheus network receive
        "sum(rate(container_network_transmit_bytes_total{${KEPLER_LABEL_MATCHER}}[2m])) by (pod)" # Kepler network transmit
        "sum(rate(container_network_transmit_bytes_total{${PROMETHUES_LABEL_MATCHER}}[2m])) by (pod)" # Prometheus network transmit
    )

    QUERY_NAMES=(
        "kepler-cpu"
        "prometheus-cpu"
        "kepler-memory"
        "prometheus-memory"
        "kepler-network-receive"
        "prometheus-network-receive"
        "kepler-network-transmit"
        "prometheus-network-transmit"
    )

    for i in ${!QUERIES[@]}; do
        OUTPUT_FILE=${OUTPUT_DIR}${QUERY_NAMES[$i]}.csv
        curl -X POST -d "query=${QUERIES[$i]}&start=${START}&end=${END}&step=30s" "${PROM_SERVER}/api/v1/query_range" | jq '.data.result[].values' > $OUTPUT_FILE
    done
}

function run_benchmark(){
    validate_cluster

    START=$(date +%s)

    prepare_output_dir

    bash -c "$EXPERIMENT_CMD"

    END=$(date +%s)

    save_overhead_data
}

"$@"