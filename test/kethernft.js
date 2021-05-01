const { expect } = require('chai');

const BN = ethers.BigNumber.from;

const weiPixelPrice = ethers.utils.parseUnits("0.001", "ether");
const pixelsPerCell = ethers.BigNumber.from(100);
const oneHundredCellPrice = pixelsPerCell.mul(weiPixelPrice).mul(100);

describe('KetherNFT', function() {
  let KetherHomepage, KetherNFT, Wrapper;
  let accounts, KH, KNFT;

  beforeEach(async() => {
    // NOTE: We're using V2 here because it's ported to newer solidity so we can debug more easily. It should also work with V1.
    KetherHomepage = await ethers.getContractFactory("KetherHomepageV2");
    KetherNFT = await ethers.getContractFactory("KetherNFT");
    Wrapper = await ethers.getContractFactory("Wrapper");


    const [owner, withdrawWallet, metadataSigner, account1, account2, account3] = await ethers.getSigners();
    accounts = {owner, withdrawWallet, metadataSigner, account1, account2, account3};

    KH = await KetherHomepage.deploy(await owner.getAddress(), await withdrawWallet.getAddress());
    KNFT = await KetherNFT.deploy(KH.address, await metadataSigner.getAddress());
  });

  const buyAd = async function(account, x=0, y=0, width=10, height=10, link="link", image="image", title="title", NSFW=false, value=oneHundredCellPrice) {
    const txn = await KH.connect(account).buy(x, y, width, height, { value: value });
    const receipt = await txn.wait();
    const event = receipt.events.pop();
    const [idx] = event.args;
    await KH.connect(account).publish(idx, link, image, title, false);
    return idx;
  }

  it("wrap ad with KetherNFT", async function() {
    const {account1} = accounts;

    // Buy an ad
    const idx = await buyAd(account1);
    expect(idx).to.equal(0);

    // TODO: Test wrapping to non-owner
    // TODO: Test wrapping by non-owner

    const [salt, precomputeAddress] = await KNFT.connect(account1).precompute(idx, await account1.getAddress());

    // Set owner to precommitted wrap address
    await KH.connect(account1).setAdOwner(idx, precomputeAddress);

    // Wrap ad
    await KNFT.connect(account1).wrap(idx, await account1.getAddress());

    // Confirm owner can't publish directly anymore
    await expect(
      KH.connect(account1).publish(idx, "foo", "bar", "baaz", false)
    ).to.be.reverted;

    {
      const [addr,,,,,link,image,title] = await KH.ads(idx);
      expect(addr).to.equal(KNFT.address);
      expect(link).to.equal("link");
      expect(image).to.equal("image");
      expect(title).to.equal("title");
    }

    // Confirm NFT owner can publish through the NFT
    await KNFT.connect(account1).publish(idx, "foo2", "bar2", "baaz2", false);

    {
      const [addr,,,,,link,image,title] = await KH.ads(idx);
      expect(addr).to.equal(KNFT.address);
      expect(link).to.equal("foo2");
      expect(image).to.equal("bar2");
      expect(title).to.equal("baaz2");
    }

  });

  it('wrap to non-owner', async function() {
    const {account1, account2, account3} = accounts;
    const idx = await buyAd(account1);
    {
      const otherIdx = await buyAd(account2, x=20, y=20);
      expect(otherIdx).to.not.equal(idx);
    }

    // Generate precommit to wrap idx (owned by account1) to ownership of account2.
    // Note that account2 can generate this precommit, as in this case.
    const [salt, precomputeAddress] = await KNFT.connect(account2).precompute(idx, await account2.getAddress());

    // Non-owner cannot change the ad ownership to precomputed address.
    await expect(
      KH.connect(account2).setAdOwner(idx, precomputeAddress)
    ).to.be.reverted;

    // Non-owner cannot wrap, either
    await expect(
      KNFT.connect(account2).wrap(idx, await account2.getAddress())
    ).to.be.revertedWith("KetherNFT: owner needs to be the correct precommitted address");

    // Same precomputed transaction is fine for the owner to run (precommit wrap to account2)
    await KH.connect(account1).setAdOwner(idx, precomputeAddress);

    // Rando can't wrap to themselves
    await expect(
      KNFT.connect(account3).wrap(idx, await account3.getAddress())
    ).to.be.revertedWith("KetherNFT: owner needs to be the correct precommitted address");

    // Rando can't wrap to owner (since the precommit is for account2)
    await expect(
      KNFT.connect(account3).wrap(idx, await account1.getAddress())
    ).to.be.revertedWith("KetherNFT: owner needs to be the correct precommitted address");

    // Rando *can* wrap to the precommitted account2
    // FIXME: Is this desirable? It allows non-owner to pay for the wrap, which is nice.
    await KNFT.connect(account3).wrap(idx, await account2.getAddress())

  });

  it("verify precompute", async function() {
    const idx = 42;
    const account = accounts.account1;

    const [salt, precomputeAddress] = await KNFT.connect(account).precompute(42, await account.getAddress());

    {
      // Validate salt generation
      const expected = ethers.utils.sha256(await account.getAddress());
      expect(salt).to.equal(expected);
    }

    const wrappedPayload = KH.interface.encodeFunctionData("setAdOwner", [idx, KNFT.address]); // Confirmed this matches KetherNFT._wrapPayload

    {
      // Validate wrapped payload encoding
      const expected = KH.interface.encodeFunctionData('setAdOwner', [idx, KNFT.address]);
      expect(wrappedPayload).to.equal(expected);
    }

    const bytecode = ethers.utils.hexlify(
      ethers.utils.concat([
        Wrapper.bytecode,
        Wrapper.interface.encodeDeploy([KH.address, wrappedPayload]),
        // Same as: ethers.utils.defaultAbiCoder.encode(['address', 'bytes'], [KH.address, wrappedPayload]),
      ]));

    {
      // Validate full create2 address precompute
      const expected = ethers.utils.getCreate2Address(KNFT.address, salt, ethers.utils.keccak256(bytecode));
      expect(precomputeAddress).to.equal(expected);
    }
  });

});

