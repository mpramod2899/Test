#!/bin/sh
/opt/kafkaconnector/rabitmq-connector/confluent-6.2.0/bin/connect-distributed -daemon /opt/kafkaconnector/rabitmq-connector/config/connect-tch.properties

echo "Verify the logs in the Following location"
echo "/opt/kafkaconnector/rabitmq-connector/confluent-6.2.0/logs/connect.log"
echo "/opt/kafkaconnector/rabitmq-connector/confluent-6.2.0/logs/connectDistributed.out"
