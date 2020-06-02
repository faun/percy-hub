FROM phusion/passenger-ruby26:latest

# Configure the apps to be supervised.
ADD bin/schedule-jobs.sh /etc/service/schedule-jobs/run
ADD bin/enqueue-jobs.sh /etc/service/enqueue-jobs/run
ADD bin/reap-workers.sh /etc/service/reap-workers/run
ADD bin/reap-locks.sh /etc/service/reap-locks/run
RUN chmod +x /etc/service/*/run

ARG SOURCE_COMMIT_SHA
ENV SOURCE_COMMIT_SHA=$SOURCE_COMMIT_SHA

# Install app.
ADD . /app/src/
# Make sure all the directory contents are owned by the app user.
RUN chown -R app:app /app/src/

WORKDIR /app/src/
RUN /sbin/setuser app gem install bundler -v 2.1.4
ARG BUNDLE_INSTALL_FLAGS="--jobs 5 --without development:test --deployment"
RUN /sbin/setuser app bundle install $BUNDLE_INSTALL_FLAGS
