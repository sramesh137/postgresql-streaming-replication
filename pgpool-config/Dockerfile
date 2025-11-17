# Dockerfile for Pgpool-II
FROM debian:bullseye-slim

# Install pgpool-II
RUN apt-get update && apt-get install -y \
    pgpool2 \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Copy custom configuration files
COPY pgpool.conf /etc/pgpool2/pgpool.conf
COPY pcp.conf /etc/pgpool2/pcp.conf
COPY pool_hba.conf /etc/pgpool2/pool_hba.conf
COPY pool_passwd /etc/pgpool2/pool_passwd

# Create required directories
RUN mkdir -p /var/run/pgpool /var/log/pgpool && \
    chown -R postgres:postgres /var/run/pgpool /var/log/pgpool /etc/pgpool2

# Expose ports
EXPOSE 9999 9898

USER postgres

CMD ["pgpool", "-n", "-f", "/etc/pgpool2/pgpool.conf", "-F", "/etc/pgpool2/pcp.conf", "-a", "/etc/pgpool2/pool_hba.conf"]
