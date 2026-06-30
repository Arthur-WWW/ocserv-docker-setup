#!/bin/bash

# A helper script to manage ocserv users within the Docker container

CONTAINER_NAME="ocserv_server"
OCPASSWD_CMD="docker exec -it $CONTAINER_NAME ocpasswd -c /etc/ocserv/config/ocpasswd"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 {add|delete|lock|unlock|list} [username]"
    exit 1
fi

COMMAND=$1
USERNAME=$2

if [ "$COMMAND" != "list" ] && [ -z "$USERNAME" ]; then
    echo "Error: Username required for command '$COMMAND'"
    echo "Usage: $0 $COMMAND <username>"
    exit 1
fi

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Error: Container '$CONTAINER_NAME' is not running."
    echo "Please start the VPN server first using 'docker-compose up -d'."
    exit 1
fi

case $COMMAND in
    add)
        echo "Adding user '$USERNAME'..."
        $OCPASSWD_CMD "$USERNAME"
        ;;
    delete)
        echo "Deleting user '$USERNAME'..."
        $OCPASSWD_CMD -d "$USERNAME"
        ;;
    lock)
        echo "Locking user '$USERNAME'..."
        $OCPASSWD_CMD -l "$USERNAME"
        ;;
    unlock)
        echo "Unlocking user '$USERNAME'..."
        $OCPASSWD_CMD -u "$USERNAME"
        ;;
    list)
        echo "Current users in the system:"
        docker exec -it $CONTAINER_NAME cat /etc/ocserv/config/ocpasswd | cut -d ':' -f 1
        ;;
    *)
        echo "Invalid command: $COMMAND"
        echo "Usage: $0 {add|delete|lock|unlock|list} [username]"
        exit 1
        ;;
esac
