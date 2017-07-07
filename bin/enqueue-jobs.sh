#!/bin/bash

cd /app/src/
exec /sbin/setuser app bundle exec bin/percy-hub enqueue_jobs 2>&1
