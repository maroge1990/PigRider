# PigRider (iPad) checks. Run on top of the repo's `make check`.
.PHONY: check web-test mac-test

check: web-test mac-test

web-test:
	cd .. && node --test "apple/web/test/**/*.test.js"

mac-test:
	./scripts/mac.sh test
