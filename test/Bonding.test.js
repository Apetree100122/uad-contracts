const { expect, use } = require("chai");
const { describe, it, beforeEach } = require("mocha");
const { ethers, deployments, waffle, getNamedAccounts } = require("hardhat");

const provider = waffle.provider;
const { deploy } = deployments;
const { solidity } = waffle;
use(solidity);

describe("Bonding", () => {
  let Bonding;
  let bonding;
  let treasury;
  let secondAccount;
  let sablier;
  let USDC;

  beforeEach(async () => {
    ({ sablier, USDC } = await getNamedAccounts());
    [treasury, secondAccount] = await ethers.getSigners();

    await deploy("Bonding", { from: treasury.address, args: [sablier] });
    Bonding = await deployments.get("Bonding");
    bonding = new ethers.Contract(Bonding.address, Bonding.abi, provider);
  });

  it("Owner should be the treasury", async () => {
    expect(await bonding.owner()).to.equal(treasury.address);
  });

  it("Should return the current Sablier address", async () => {
    expect(await bonding.sablier()).to.equal(sablier);
  });

  it("Treasury should be able to update the Sablier address", async () => {
    await bonding.connect(treasury).setSablier(ethers.constants.AddressZero);
    expect(await bonding.sablier()).to.equal(ethers.constants.AddressZero);
  });

  it("Should revert when another account tries to update the Sablier address", async () => {
    await expect(
      bonding.connect(secondAccount).setSablier(ethers.constants.AddressZero)
    ).to.be.revertedWith("caller is not the owner");
  });

  it("Owner should be able to add protocol token (CollectableDust)", async () => {
    await bonding.connect(treasury).addProtocolToken(USDC);
  });

  it("Should revert when another account tries to add protocol token (CollectableDust)", async () => {
    await expect(
      bonding.connect(secondAccount).addProtocolToken(USDC)
    ).to.be.revertedWith("caller is not the owner");
  });

  it("Should revert when trying to add an already existing protocol token (CollectableDust)", async () => {
    await expect(
      bonding.connect(treasury).addProtocolToken(USDC)
    ).to.be.revertedWith("collectable-dust::token-is-part-of-the-protocol");
  });

  it("Should revert when another account tries to remove a protocol token (CollectableDust)", async () => {
    await expect(
      bonding.connect(secondAccount).removeProtocolToken(USDC)
    ).to.be.revertedWith("caller is not the owner");
  });

  it("Owner should be able to remove protocol token (CollectableDust)", async () => {
    await bonding.connect(treasury).removeProtocolToken(USDC);
  });

  it("Should revert when trying to remove token that is not a part of the protocol (CollectableDust)", async () => {
    await expect(
      bonding.connect(treasury).removeProtocolToken(USDC)
    ).to.be.revertedWith("collectable-dust::token-not-part-of-the-protocol");
  });

  it("Owner should be able to send dust from the contract (CollectableDust)", async () => {
    // Send ETH to the Bonding contract
    await secondAccount.sendTransaction({
      to: bonding.address,
      value: ethers.utils.parseUnits("100", "gwei"),
    });

    // Send dust back to the treasury
    await bonding
      .connect(treasury)
      .sendDust(
        treasury.address,
        "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
        ethers.utils.parseUnits("100", "gwei")
      );
  });

  it("Should revert when another account tries to remove dust from the contract (CollectableDust)", async () => {
    await expect(
      bonding
        .connect(secondAccount)
        .sendDust(
          treasury.address,
          "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
          ethers.utils.parseUnits("100", "gwei")
        )
    ).to.be.revertedWith("caller is not the owner");
  });
});