build:
	docker-compose build

up:
	docker-compose up

test:
	docker-compose run hub /sbin/setuser app bundle exec rspec