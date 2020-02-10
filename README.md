# docker-cassandra-cluster

Dockerized Cassandra cluster, so you can play with it ;-)

# Software dependencies

* docker (duh)
* ipcalc
* bc

# Usage

```
./main.sh

Command options:
    -b      Bootstrap the cassandra cluster
    -s      Start all the cluster nodes
    -k      Stop all the cluster nodes
    -d      Destroy the cluster :- WARNING -: ALL DATA WILL BE LOST
    -l      Display the cluster status using nodetool
    -r      Display the cluster ring tokens using nodetool
    -c      Launch CQL shell
```