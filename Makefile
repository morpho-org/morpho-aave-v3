-include .env
.EXPORT_ALL_VARIABLES:
MAKEFLAGS += --no-print-directory

install:
	yarn
	foundryup
	forge install

contracts:
	FOUNDRY_TEST=/dev/null FOUNDRY_SCRIPT=/dev/null forge build --via-ir --extra-output-files irOptimized --sizes --force


test-invariant:
	@FOUNDRY_MATCH_CONTRACT=TestInvariant make test

test-integration:
	@FOUNDRY_MATCH_CONTRACT=TestIntegration make test

test-internal:
	@FOUNDRY_MATCH_CONTRACT=TestInternal make test

test-prod:
	@FOUNDRY_MATCH_CONTRACT=TestProd make test

test-unit:
	@FOUNDRY_MATCH_CONTRACT=TestUnit make test

test:
	forge test -vvv


test-invariant-%:
	@FOUNDRY_MATCH_TEST=$* make test-invariant

test-integration-%:
	@FOUNDRY_MATCH_TEST=$* make test-integration

test-internal-%:
	@FOUNDRY_MATCH_TEST=$* make test-internal

test-prod-%:
	@FOUNDRY_MATCH_TEST=$* make test-prod

test-unit-%:
	@FOUNDRY_MATCH_TEST=$* make test-unit

test-%:
	@FOUNDRY_MATCH_TEST=$* make test


test-invariant/%:
	@FOUNDRY_MATCH_CONTRACT=TestInvariant$* make test

test-integration/%:
	@FOUNDRY_MATCH_CONTRACT=TestIntegration$* make test

test-internal/%:
	@FOUNDRY_MATCH_CONTRACT=TestInternal$* make test

test-prod/%:
	@FOUNDRY_MATCH_CONTRACT=TestProd$* make test

test-unit/%:
	@FOUNDRY_MATCH_CONTRACT=TestUnit$* make test

test/%:
	@FOUNDRY_MATCH_CONTRACT=$* make test


coverage:
	forge coverage --report lcov
	lcov --remove lcov.info -o lcov.info "test/*"

lcov-html:
	@echo Transforming the lcov coverage report into html
	genhtml lcov.info -o coverage

gas-report:
	@FORGE_GAS_REPORT=true make test-integration

deploy-emode:
	FOUNDRY_TEST=/dev/null forge script script/EthEModeDeployScript.sol:EthEModeDeploy --via-ir --broadcast --slow -vvvvv --rpc-url mainnet --ledger

.PHONY: contracts test coverage
