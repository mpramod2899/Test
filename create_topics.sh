/opt/kafkaconnector/rabitmq-connector/confluent-6.2.0/bin/kafka-topics --zookeeper 127.0.0.1:2181 --create --topic confluent.connect-offsets-vm --partitions 1 --replication-factor 1 --config cleanup.policy=compact
/opt/kafkaconnector/rabitmq-connector/confluent-6.2.0/bin/kafka-topics --zookeeper 127.0.0.1:2181 --create --topic confluent.connect-status-vm --partitions 1 --replication-factor 1 --config cleanup.policy=compact
/opt/kafkaconnector/rabitmq-connector/confluent-6.2.0/bin/kafka-topics --zookeeper 127.0.0.1:2181 --create --topic confluent.connect-configs-vm --partitions 1 --replication-factor 1 --config cleanup.policy=compact
/opt/kafkaconnector/rabitmq-connector/confluent-6.2.0/bin/kafka-topics --zookeeper 127.0.0.1:2181 --create --topic test-end-to-end --partitions 1 --replication-factor 1 
/opt/kafkaconnector/rabitmq-connector/confluent-6.2.0/bin/kafka-topics --zookeeper 127.0.0.1:2181 --create --topic Test_Kafka --partitions 1 --replication-factor 1
