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
export KEPLER_PROM_SERVER=${KEPLER_PROM_SERVER:-${PROM_SERVER}} # Specify if different from default prometheus server
export KEPLER_LABEL_MATCHER=${KEPLER_LABEL_MATCHER:-'pod=~"kepler-exporter.*"'}
export PROMETHUES_LABEL_MATCHER=${PROMETHUES_LABEL_MATCHER:-'pod=~"prometheus.*"'}
export HOURS_TO_SAVE=${HOURS:-1}

function prepare_output_dir(){
    # Prepare output CSV header
    export OUTPUT_DIR=${OUTPUT_DIR:-"${RESULTS_DIR}${EXPERIMENT_DIR_NAME}/$(date -d @${START} +"%Y_%m_%d_%I_%M_%p")/"}
    mkdir -p $OUTPUT_DIR
}

function create_timestamp_file(){
    export TIMESTAMP_OUTPUT_FILE=${OUTPUT_DIR}timestamps.csv
    echo "Replicas,Start time,End time" > $TIMESTAMP_OUTPUT_FILE
}

function validate_cluster(){
    set +e
    curl -s -g "${KEPLER_PROM_SERVER}/api/v1/query?query=kepler_container_package_joules_total[5s]" | jq '.data.result[].values' --exit-status > /dev/null
    EXIT_STATUS=$?
    if [ $EXIT_STATUS -ne 0 ]; then
        if [ $EXIT_STATUS -eq 7 ]; then
            echo "Error: Could not reach Kepler Prometheus server at ${KEPLER_PROM_SERVER}"
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


function restrict_kepler_metrics_by_node(){
    PATCH='[{"op": "add", "path": "/spec/selector/exposenode", "value": "true"}]'
    kubectl patch service kepler-exporter -n kepler --type json -p "$PATCH" 2>/dev/null
    # Sleep for Prometheus scrape interval
    sleep 30
}

function unrestrict_kepler_metrics_by_node(){
    PATCH='[{"op": "remove", "path": "/spec/selector/exposenode"}]'
    kubectl patch service kepler-exporter -n kepler --type json -p "$PATCH" 2>/dev/null
    # Sleep for Prometheus scrape interval
    sleep 30
}

function disable_kepler_pod_sraping(){
    kubectl label pod $POD exposenode=false --overwrite -n kepler
    # Sleep for Prometheus scrape interval
    sleep 30
}

function record_current_interval(){
    echo -n "${KEPLER_POD_COUNT},$(date +%s)," >> $TIMESTAMP_OUTPUT_FILE

    sleep $INCREMENT_INTERVAL

    echo "$(date +%s)" >> $TIMESTAMP_OUTPUT_FILE
}

function scale_cluster(){
    KEPLER_PODS=($(kubectl get pods -l app.kubernetes.io/name=kepler-exporter -n kepler -o custom-columns="NAME:.metadata.name" --no-headers))
    KEPLER_POD_COUNT=${#KEPLER_PODS[@]}

    kubectl label pods ${KEPLER_PODS[@]} exposenode="true" --overwrite -n kepler

    # Only expose kepler metrics to Prometheus for nodes with a kepler-exporter with the label exposenode="true"
    restrict_kepler_metrics_by_node

    echo "Nodes,Start time,End time" > $TIMESTAMP_OUTPUT_FILE

    # Benchmark the overhead when all nodes are being scraped
    record_current_interval

    COUNT=$INCREMENT
    for POD in ${KEPLER_PODS[@]}
    do
        if [ "$COUNT" -eq 0 ]; then
            COUNT="$INCREMENT"

            disable_kepler_pod_sraping
            
            record_current_interval
        fi
        COUNT=$((COUNT - 1))
        KEPLER_POD_COUNT=$((KEPLER_POD_COUNT - 1))
    done

    # Benchmark the overhead when all kepler metrics aren't exposed for any nodes
    record_current_interval

    #cleanup
    unrestrict_kepler_metrics_by_node
    kubectl label pods ${KEPLER_PODS[@]} exposenode- -n kepler
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

    create_timestamp_file

    bash -c "$EXPERIMENT_CMD"

    END=$(date +%s)

    save_overhead_data
}

function save_current_overhead(){
    END=$(date +%s)
    START=$((END - $((HOURS_TO_SAVE * 3600))))

    export OUTPUT_DIR=${OUTPUT_DIR:-"./_output/overhead-snapshots/$(date -d @${END} +"%Y_%m_%d_%I_%M_%p")/"}
    prepare_output_dir

    save_overhead_data
}

"$@"