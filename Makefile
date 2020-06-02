build:
	docker-compose build \
		--build-arg SOURCE_COMMIT_SHA=$$(git describe --always --tags --dirty --abbrev=7)

down:
	docker-compose down

up:
	docker-compose up

up-detached:
	docker-compose up -d

su:
	docker-compose exec hub bash

bash:
	docker-compose exec hub /sbin/setuser app bash

_set-container-permissions:
	@cat /etc/group | grep docker-apps > /dev/null || groupadd -g 9999 docker-apps >/dev/null 2>&1 || true
	@usermod -a -G docker-apps $$(whoami) >/dev/null 2>&1 || true
	@chgrp -R 9999 .
	@chmod -R g+w .

test: _set-container-permissions
	docker-compose exec hub /sbin/setuser app bundle exec rspec

rubocop: _set-container-permissions
	@echo "--- Rubocop"
	@mkdir -p ./tmp/rubocop
	@chgrp -R 9999 ./tmp/rubocop
	@chmod -R g+w ./tmp/rubocop
	docker-compose exec hub /sbin/setuser app bundle exec rubocop -D --parallel -f emacs -o ./tmp/rubocop/output.txt

publish:
	@bin/publish.sh "$$(git describe --always --tags --dirty --abbrev=7)"
