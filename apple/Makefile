# PigRider (iPad) checks. Run on top of the repo's `make check`.
.PHONY: check web-test mac-test ipad testflight

check: web-test mac-test

web-test:
	cd .. && node --test "apple/web/test/**/*.test.js"

mac-test:
	./scripts/mac.sh test

# Signed builds (need the Mac password typed in this terminal).
ipad:
	./scripts/mac.sh ipad

testflight:
	./scripts/mac.sh testflight
