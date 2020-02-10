#!/usr/bin/env bash

set -e

createNetwork() {
  local networkName=$1
  local networkSubnetPart=$2

  docker network rm ${networkName} 2> /dev/null || true
  docker network create --subnet="${networkSubnetPart}.0/24" ${networkName}
}

getNetworkAddresses() {
  local clusterSize=$1
  local networkSubnetPart=$2
  local networkStartIP=$3

  echo $(seq -f "${networkSubnetPart}.%g" ${networkStartIP} $(echo "${networkStartIP}+${clusterSize}-1" | bc))
}

function joinBy {
  local IFS="${1}"
  shift
  echo "$*"
}

getSeedIPAddresses() {
  local networkAddresses=("$@")
  declare -a clusterSeeds

  for index in ${!networkAddresses[@]};
  do
    if [[ ${index} < 3 ]]; then
      clusterSeeds+=(${networkAddresses[${index}]})
    fi
  done

  echo $(joinBy , ${clusterSeeds[@]})
}

createNode() {
  local clusterName=$1
  local nodeName=$2
  local nodeMemory=$3
  local nodeAddress=$4
  local rackName=$5
  local clusterSeeds=$6
  local exposePort=$7

  local port=""
  if [[ ${exposePort} == true ]]; then
    local port="-p 9042:9042"
  fi

  docker run \
    --memory=${nodeMemory} \
    --name ${nodeName} \
    --net ${clusterName} \
    --ip ${nodeAddress} \
    ${port} \
    -e CASSANDRA_SEEDS=${clusterSeeds} \
    -e CASSANDRA_CLUSTER_NAME=${clusterName} \
    -e CASSANDRA_ENDPOINT_SNITCH=GossipingPropertyFileSnitch \
    -e CASSANDRA_DC=DC1 \
    -e CASSANDRA_RACK=${rackName} \
    -e CASSANDRA_NUM_TOKENS=16 \
    -d cassandra
}

function readInput() {
  local inputQuestion=$1
  local defaultValue=$2

  input=
  while [[ ${input} = "" ]]; do
    read -p "${inputQuestion} [${defaultValue}]: " input
    input=${input:-${defaultValue}}
  done

  echo ${input}
}

function writeConfig() {
  local envFile=$1
  scratch=$(mktemp -t docker-cassandra)
  trap "cat ${scratch} && rm ${scratch}" EXIT

  echo "CLUSTER_NAME=$(readInput "What is the Cluster name?" "cassandra_cluster")" > ${scratch}
  echo "CLUSTER_SIZE=$(readInput "What should be the cluster size (1/2/4)?" 4)" >> ${scratch}
  echo "NODE_MEMORY=$(readInput "How much memory should be allocated per node (1g/2g/4g)?" 4g)" >> ${scratch}
  echo "NETWORK_SUBNET_PART=$(readInput "What is the network prefix?" "192.168.100")" >> ${scratch}
  cp ${scratch} ${envFile}
}


function checkConfig() {
  local envFile=$1

  if [[ ! -f ${envFile} ]]; then
    writeConfig ${envFile}
  fi
}

function loadConfig() {
  local varName=$1
  local envFile=$2
  checkConfig ${envFile}

  grep ${varName} ${envFile} | awk -F '=' '{ print $2 }'
}

PROJECT_PATH=$(dirname "$0")
ENV_CONFIG_FILE="${PROJECT_PATH}/.env"
CLUSTER_NAME=$(loadConfig CLUSTER_NAME ${ENV_CONFIG_FILE})
CLUSTER_SIZE=$(loadConfig CLUSTER_SIZE ${ENV_CONFIG_FILE})
NODE_MEMORY=$(loadConfig NODE_MEMORY ${ENV_CONFIG_FILE})
NETWORK_SUBNET_PART=$(loadConfig NETWORK_SUBNET_PART ${ENV_CONFIG_FILE})

function bootStrap() {
  createNetwork ${CLUSTER_NAME} ${NETWORK_SUBNET_PART}
  local networkAddresses=($(getNetworkAddresses ${CLUSTER_SIZE} ${NETWORK_SUBNET_PART} 2))
  local clusterSeeds=$(getSeedIPAddresses ${networkAddresses[@]})

  for index in ${!networkAddresses[@]};
  do
    createNode \
      ${CLUSTER_NAME} \
      "${CLUSTER_NAME}_${index}" \
      ${NODE_MEMORY} \
      ${networkAddresses[${index}]} \
      "rc-${index}" \
      "${clusterSeeds}" \
      $(((${index})) && echo "false" || echo "true")
  done
}

function startCluster() {
  echo "Starting all cluster nodes"
  docker start $(docker container ls -qa --filter name=${CLUSTER_NAME}) || echo "Could not start the cluster nodes" 1>&2
}

function stopCluster() {
  echo "Stopping all cluster nodes"
  docker stop $(docker container ls -qa --filter name=${CLUSTER_NAME}) || echo "Could not stop the cluster nodes" 1>&2
}

function destroyCluster() {
  echo "Removing cluster nodes"
  docker rm $(docker container ls -qa --filter name=${CLUSTER_NAME}) || true
  echo "Removing cluster network"
  docker network rm ${CLUSTER_NAME} || true
}

function clusterStatus() {
  echo "Displaying cassandra node status"
  docker exec -ti "${CLUSTER_NAME}_0" nodetool status || echo "Could not detect status of cluster" 1>&2
}

function clusterRing() {
  echo "Fetching Cluster tokens"
  docker exec -ti "${CLUSTER_NAME}_0" nodetool ring || echo "Could not fetch cluster tokens" 1>&2
}

function startCQLShell() {
  echo "Starting Cassandra Query Language shell"
  docker exec -ti "${CLUSTER_NAME}_0" cqlsh
}

function usage() {
  cat << EOF
${0}
Command options:
    -b      Bootstrap the cassandra cluster
    -s      Start all the cluster nodes
    -k      Stop all the cluster nodes
    -d      Destroy the cluster :- WARNING -: ALL DATA WILL BE LOST
    -l      Display the cluster status using nodetool
    -r      Display the cluster ring tokens using nodetool
    -c      Launch CQL shell

EOF
  exit 1
}

function invalidOption() {
    echo "Invalid Command: -$OPTARG" 1>&2
}

function invalidOptionParameter() {
    echo "Invalid Option: -$OPTARG" 1>&2
}

function optionParameterRequiresValue() {
    echo "Option: -$OPTARG requires an argument" 1>&2
}

while getopts :hbksdlrc option
do
  case "${option}" in
  h )
    usage
    ;;
  b )
    bootStrap
    ;;
  k )
    stopCluster
    ;;
  s )
    startCluster
    ;;
  d )
    stopCluster && destroyCluster
    ;;
  l )
    clusterStatus
    ;;
  r )
    clusterRing
    ;;
  c )
    startCQLShell
    ;;
  \? )
    invalidOptionParameter && usage
    ;;
  : )
    optionParameterRequiresValue && usage
    ;;
  esac
done

if [[ $OPTIND -eq 1 ]]; then
    usage
fi

exit 0