build: deps contracts

test: deps contracts
	npx hardhat test

run: deps contracts
	npm run dev

deploy-dapp: build ../thousandetherhomepage.github.io
	tar -C build -c js css img press faq index.html | tar -C ../thousandetherhomepage.github.io/ -xv
	cd ../thousandetherhomepage.github.io; git add -v -A; git commit -v -a
	echo "Push it."

deploy-contract:
	# TODO: $(TRUFFLEBIN) migrate -f 2 --network rinkeby --reset

withdraw:
	npx hardhat run scripts/withdraw.js --network mainnet

deps: node_modules/

contracts: build/contracts/*

build/contracts/%.json: contracts/%.sol
	npx hardhat compile

node_modules/: package.json package-lock.json
	npm install
	touch node_modules/
