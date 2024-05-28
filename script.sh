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
export KEPLER_PROM_LABEL_MATCHER=${KEPLER_PROM_LABEL_MATCHER:-'pod=~"prometheus.*"'} # Should only match prometheus instance targeting Kepler
export MULTIPLE_KEPLER_PROM_INSTANCES=${MULTIPLE_KEPLER_PROM_INSTANCES:-false}
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

    CURL_OUTPUT=$(curl -s -g "${PROM_SERVER}/api/v1/query?query=container_cpu_usage_seconds_total{${KEPLER_PROM_LABEL_MATCHER},container=\"prometheus\"}")
    MATCHING_PROM_INSTANCE_COUNT=$(echo $CURL_OUTPUT | jq '.data.result | length')
    MATCHING_PROM_INSTANCES=$(echo $CURL_OUTPUT | jq '.data.result[].metric.pod')
    if [ $MATCHING_PROM_INSTANCE_COUNT -eq 1 ]; then
        echo -e "Measuring overhead of a single Prometheus pod: ${MATCHING_PROM_INSTANCES}"
    elif [ "${MULTIPLE_KEPLER_PROM_INSTANCES,,}" = true ]; then
        echo -e "Measuring average overhead of multiple Prometheus pods:\n${MATCHING_PROM_INSTANCES}"
    else
        echo -e "Error: Multiple Prometheus pods are being targeted:\n${MATCHING_PROM_INSTANCES}"
        echo "Help: If intentionally scraping Kepler metrics from multiple Prometheus instances, set MULTIPLE_KEPLER_PROM_INSTANCES=true"
        echo "Help: If more Prometheus instances are being targeted than desired set KEPLER_PROM_LABEL_MATCHER (currently KEPLER_PROM_LABEL_MATCHER='${KEPLER_PROM_LABEL_MATCHER}') to only match desired Prometheus pod(s)"
        exit 1
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

function enable_kepler_pod_sraping(){
    kubectl label pod $POD exposenode=true --overwrite -n kepler
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
    KEPLER_POD_COUNT=0

    kubectl label pods ${KEPLER_PODS[@]} exposenode="false" --overwrite -n kepler

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

            enable_kepler_pod_sraping
            
            record_current_interval
        fi
        COUNT=$((COUNT - 1))
        KEPLER_POD_COUNT=$((KEPLER_POD_COUNT + 1))
    done

    # Benchmark the overhead when all kepler metrics aren't exposed for any nodes
    record_current_interval

    #cleanup
    unrestrict_kepler_metrics_by_node
    kubectl label pods ${KEPLER_PODS[@]} exposenode- -n kepler
}

function save_overhead_data(){
    # The plotting functions expect a single timeseries
    # Wrapping queries in a final aggregation function guarantees this
    QUERIES=(
        "max(avg(rate(container_cpu_usage_seconds_total{${KEPLER_LABEL_MATCHER}}[2m])) by (pod))" # max Kepler cpu
        "avg(avg(rate(container_cpu_usage_seconds_total{${KEPLER_LABEL_MATCHER}}[2m])) by (pod))" # average Kepler cpu
        "avg(rate(container_cpu_usage_seconds_total{${KEPLER_PROM_LABEL_MATCHER}}[2m]))" # average Prometheus cpu (in case of multiple Prometheus instances)
        "max(avg(rate(container_memory_usage_bytes{${KEPLER_LABEL_MATCHER}}[2m])) by (pod))" # max Kepler memory
        "avg(avg(rate(container_memory_usage_bytes{${KEPLER_LABEL_MATCHER}}[2m])) by (pod))" # average Kepler memory
        "avg(rate(container_memory_usage_bytes{${KEPLER_PROM_LABEL_MATCHER}}[2m]))" # average Prometheus memory (in case of multiple Prometheus instances)
        "max(rate(container_network_receive_bytes_total{${KEPLER_LABEL_MATCHER}}[2m]))" # max Kepler network receive
        "avg(rate(container_network_receive_bytes_total{${KEPLER_LABEL_MATCHER}}[2m]))" # avg Kepler network receive
        "avg(rate(container_network_receive_bytes_total{${KEPLER_PROM_LABEL_MATCHER}}[2m]))" # Prometheus network receive
        "max(rate(container_network_transmit_bytes_total{${KEPLER_LABEL_MATCHER}}[2m]))" # max Kepler network transmit
        "avg(rate(container_network_transmit_bytes_total{${KEPLER_LABEL_MATCHER}}[2m]))" # avg Kepler network transmit
        "avg(rate(container_network_receive_bytes_total{${KEPLER_PROM_LABEL_MATCHER}}[2m]))" # Prometheus network transmit
    )

    QUERY_NAMES=(
        "max-kepler-cpu"
        "avg-kepler-cpu"
        "avg-prometheus-cpu"
        "max-kepler-memory"
        "avg-kepler-memory"
        "avg-prometheus-memory"
        "max-kepler-network-receive"
        "avg-kepler-network-receive"
        "avg-prometheus-network-receive"
        "max-kepler-network-transmit"
        "avg-kepler-network-transmit"
        "avg-prometheus-network-transmit"
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