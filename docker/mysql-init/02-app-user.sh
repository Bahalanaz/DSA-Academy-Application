#!/bin/bash
# Runs once, when the MySQL container starts with an empty data volume, after
# 01-schema.sql. Creates the server's own MySQL user (the server never
# connects as root) with exactly the rights in app_user_grants.sql, allowed
# from the other containers rather than only from localhost.

: "${DSA_DB_PASSWORD:?DSA_DB_PASSWORD is not set (see docker.env.example)}"

mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE USER 'dsa_app_user'@'%' IDENTIFIED BY '${DSA_DB_PASSWORD}';
SQL

sed "s/'dsa_app_user'@'localhost'/'dsa_app_user'@'%'/" /dsa/app_user_grants.sql |
  mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD"
