FROM quay.io/debezium/connect:latest

# Download and install MongoDB Kafka Connector
RUN cd /kafka/connect && \
    curl -L https://repo1.maven.org/maven2/org/mongodb/kafka/mongo-kafka-connect/1.13.0/mongo-kafka-connect-1.13.0-all.jar \
    -o mongo-kafka-connect-1.13.0-all.jar

USER kafka
