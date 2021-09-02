curl -X "POST" http://localhost:8088/query -H "Accept: application/vnd.ksql.v1+json" -u ksql:lPf5C6JjJN7BW7HjJhOn#  -d $'{
  "ksql": "SELECT * FROM SRC_JSON EMIT CHANGES;",
  "streamsProperties": {
      "ksql.streams.auto.offset.reset": "earliest"
   }
}'
