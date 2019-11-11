#!/bin/bash

cd /app/src/
exec /sbin/setuser app bundle exec bin/percy-hub reap_locks 2>&1
