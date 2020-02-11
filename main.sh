#!/usr/bin/env bash

set -e

function createNetwork() {
  local networkName=$1
  local networkCIDR=$2

  docker network rm ${networkName} 2> /dev/null || true
  echo "Creating cluster network"
  docker network create --subnet=${networkCIDR} ${networkName}
}

function getNextIPAddress(){
  local ipAddress="${1}"

  ipAddressHEX=$(printf '%.2X%.2X%.2X%.2X\n' $(echo ${ipAddress} | sed -e 's/\./ /g'))
  nextIPAddressHEX=$(printf %.8X $(echo $(( $(echo "0x${ipAddressHEX}") + 1 ))))
  nextIPAddress=$(printf '%d.%d.%d.%d\n' $(echo ${nextIPAddressHEX} | sed 's/../0x& /g'))
  echo "$nextIPAddress"
}

function getIPList() {
  local ipAddress="${1}"
  local ipCount="${2}"
  for i in $(seq 1 ${ipCount}); do
    ipAddress=$(getNextIPAddress ${ipAddress})
    echo ${ipAddress}
  done
}

function getFirstIPAddress() {
  local networkCIDR="${1}"
  echo $(ipcalc ${networkCIDR} | grep "HostMin" | awk '{ print $2 }')
}

function getNetworkAddresses() {
  local ipCount=$1
  local networkCIDR=$2

  getIPList $(getFirstIPAddress ${networkCIDR}) ${ipCount}
}

function joinBy {
  local IFS="${1}"
  shift
  echo "$*"
}

function getSeedIPAddresses() {
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

function createNode() {
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

  echo "Creating node ${nodeName} in cluster"
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
  echo "NETWORK_CIDR=$(readInput "What is the network CIDR?" "192.168.100.0/27")" >> ${scratch}
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

  grep ${varName} ${envFile} | awk -F '=' '{ print $2 }'
}

function pauseBootstrap() {
  local waitTime=${1}

  echo "Pausing bootstrap for ${waitTime} seconds"
  sleep ${waitTime}
}

PROJECT_PATH=$(dirname "$0")
ENV_CONFIG_FILE="${PROJECT_PATH}/.env"
checkConfig ${ENV_CONFIG_FILE}

CLUSTER_NAME=$(loadConfig CLUSTER_NAME ${ENV_CONFIG_FILE})
CLUSTER_SIZE=$(loadConfig CLUSTER_SIZE ${ENV_CONFIG_FILE})
NODE_MEMORY=$(loadConfig NODE_MEMORY ${ENV_CONFIG_FILE})
NETWORK_CIDR=$(loadConfig NETWORK_CIDR ${ENV_CONFIG_FILE})

function bootStrap() {
  createNetwork ${CLUSTER_NAME} ${NETWORK_CIDR}
  local networkAddresses=($(getNetworkAddresses ${CLUSTER_SIZE} ${NETWORK_CIDR}))
  local clusterSeeds=$(getSeedIPAddresses ${networkAddresses[@]})
  local bootstrapDelay=120

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

    pauseBootstrap ${bootstrapDelay}
  done

  clusterStatus
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