.PHONY: all build format test

all: build

build:
	elm-make src/Main.elm --yes --output ./static/Main.js

format:
	elm-format --yes src tests

test:
	elm test
