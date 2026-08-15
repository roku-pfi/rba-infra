-- Runs once on first Postgres container start (empty data volume).
-- Database-per-service: each owning service gets its own DB on the shared server.
-- Redis stays a single shared instance (online profiles; profile-service writes).

CREATE DATABASE rba_decision;
CREATE DATABASE rba_profile;
CREATE DATABASE rba_audit;
CREATE DATABASE rba_idp;

-- Owner role already exists as POSTGRES_USER=rba; grant connect to each DB.
GRANT ALL PRIVILEGES ON DATABASE rba_decision TO rba;
GRANT ALL PRIVILEGES ON DATABASE rba_profile TO rba;
GRANT ALL PRIVILEGES ON DATABASE rba_audit TO rba;
GRANT ALL PRIVILEGES ON DATABASE rba_idp TO rba;
