build:
	docker-compose build

down:
	docker-compose down

up:
	docker-compose up

up-detached:
	docker-compose up -d

test:
	docker-compose exec hub /sbin/setuser app bundle exec rspec

publish:
	@bin/publish.sh
