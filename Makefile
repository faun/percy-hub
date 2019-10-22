build:
	docker-compose build

down:
	docker-compose down

up:
	docker-compose up

test:
	docker-compose run hub /sbin/setuser app bundle exec rspec

publish:
	@bin/publish.sh
