build:
	docker-compose build

down:
	docker-compose down

up:
	docker-compose up

up-detached:
	docker-compose up -d

bash:
	docker-compose exec hub bash

test:
	docker-compose exec hub /sbin/setuser app bundle exec rspec

rubocop:
	@echo "--- Rubocop"
	@mkdir -p ./tmp/rubocop
	@chgrp -R 9999 ./tmp/rubocop
	@chmod -R g+w ./tmp/rubocop
	docker-compose exec hub /sbin/setuser app bundle exec rubocop -D --parallel -f emacs -o ./tmp/rubocop/output.txt

publish:
	@bin/publish.sh
