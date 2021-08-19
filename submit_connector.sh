#!/bin/bash

HEADER="Content-Type: application/json"

curl -k -X DELETE -H "${HEADER}"  https://localhost:8083/connectors/RabbitMQ || exit 1
curl -k -X POST -H "${HEADER}" --data "@${1}"  https://localhost:8083/connectors || exit 1

