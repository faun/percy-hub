#!/bin/bash

cd /app/src/
exec /sbin/setuser app bundle exec bin/percy-hub reap_workers 2>&1
