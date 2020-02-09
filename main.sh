#!/usr/bin/env bash

set -ex

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
  local nodeAddress=$3
  local rackName=$4
  local clusterSeeds=$5
  local exposePort=$6

  local port=""
  if [[ ${exposePort} == true ]]; then
    local port="-p 9042:9042"
  fi

  docker run \
    --memory=4g \
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

function bootStrap() {
  createNetwork ${CLUSTER_NAME} ${NETWORK_SUBNET_PART}
  local networkAddresses=($(getNetworkAddresses ${CLUSTER_SIZE} ${NETWORK_SUBNET_PART} 2))
  local clusterSeeds=$(getSeedIPAddresses ${networkAddresses[@]})

  for index in ${!networkAddresses[@]};
  do
    createNode \
      ${CLUSTER_NAME} \
      "${CLUSTER_NAME}_${index}" \
      ${networkAddresses[${index}]} \
      "rc-${index}" \
      "${clusterSeeds}" \
      $(((${index})) && echo "false" || echo "true")
  done
}

PROJECT_PATH=$(dirname "$0")
ENV_CONFIG_FILE="${PROJECT_PATH}/.env"
CLUSTER_NAME=$(loadConfig CLUSTER_NAME ${ENV_CONFIG_FILE})
CLUSTER_SIZE=$(loadConfig CLUSTER_SIZE ${ENV_CONFIG_FILE})
NETWORK_SUBNET_PART=$(loadConfig NETWORK_SUBNET_PART ${ENV_CONFIG_FILE})

bootStrap

exit 0