FROM phusion/passenger-ruby23:latest

# Configure the apps to be supervised.
ADD bin/schedule-jobs.sh /etc/service/schedule-jobs/run
ADD bin/enqueue-jobs.sh /etc/service/enqueue-jobs/run
ADD bin/reap-workers.sh /etc/service/reap-workers/run
RUN chmod +x /etc/service/*/run

# Install app.
ADD . /app/src/
# Make sure all the directory contents are owned by the app user.
RUN chown -R app:app /app/src/

WORKDIR /app/src/
ARG BUNDLE_INSTALL_FLAGS="--jobs 5 --without development:test --deployment"
RUN /sbin/setuser app bundle install $BUNDLE_INSTALL_FLAGS
