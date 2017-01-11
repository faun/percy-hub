#!/bin/bash

cd /app/src/
exec /sbin/setuser app bundle exec bin/percy-hub schedule_jobs 2>&1
