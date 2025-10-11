flowchart TD
    A[("MySQL Database<br/>(Source)<br/>Port: 3306")] -->|"Binlog Reading<br/>Change Data Capture"| B["Kafka Connect<br/>(Debezium MySQL Connector)"]
    B -->|"Stream Events"| C[("Apache Kafka<br/>Message Broker<br/>Port: 9092")]
    C -->|"Consume Events"| D["Kafka Connect<br/>(JDBC Sink Connector)"]
    D -->|"Write Changes"| E[("PostgreSQL Database<br/>(Destination)<br/>Port: 5433")]
    
    F["Kafka UI (AKHQ)<br/>Port: 7080"] -.->|"Monitor"| C
    G["Debezium UI<br/>Port: 8080"] -.->|"Manage"| B
    G -.->|"Manage"| D
    
    style A fill:#e1f5fe
    style E fill:#e8f5e8
    style C fill:#fff3e0
    style B fill:#f3e5f5
    style D fill:#f3e5f5
    style F fill:#fce4ec
    style G fill:#fce4ec
