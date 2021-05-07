//SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import '@openzeppelin/contracts/utils/Strings.sol';

import "./IKetherHomepage.sol";
import "base64-sol/base64.sol";

import "hardhat/console.sol"; // XXX


// TODO: Name this something really cool
contract Wrapper {
  constructor(address target, bytes memory payload) {
    (bool success,) = target.call(payload);
    require(success, "Wrapper: target call failed");

    selfdestruct(payable(target));
  }
}

contract KetherNFT is ERC721 {
  using Strings for uint;

  /// instance is the KetherHomepage contract that this wrapper interfaces with.
  IKetherHomepage public instance;

  /// admin controls upgrading the tokenURI renderer and releasing trapped funds.
  address admin;

  /// disableRenderUpgrade is whether we can still upgrade the tokenURI renderer.
  /// Once it is set it cannot be unset.
  // TODO: bool disableRenderUpgrade = false;

  constructor(address _ketherContract, address _admin) ERC721("Thousand Ether Homepage Ad", "1KAD") {
    instance = IKetherHomepage(_ketherContract);
    admin = _admin;
  }

  function _encodeWrapper(uint _idx) internal view returns (bytes memory) {
    return abi.encodePacked(
      type(Wrapper).creationCode,
      abi.encode(address(instance), _encodeWrapperPayload(_idx)));
  }

  function _encodeWrapperPayload(uint _idx) internal view returns (bytes memory) {
    return abi.encodeWithSignature("setAdOwner(uint256,address)", _idx, address(this));
  }

  function precompute(uint _idx, address _owner) public view returns (bytes32 salt, address predictedAddress) {
    salt = sha256(abi.encodePacked(_owner)); // FIXME: This can be more gas-efficient? Also worth salting something random here like block number?

    bytes memory bytecode = _encodeWrapper(_idx);

    bytes32 hash = keccak256(
      abi.encodePacked(
        bytes1(0xff),
        address(this),
        salt,
        keccak256(bytecode)
      )
    );

    predictedAddress = address(uint160(uint256(hash)));
    return (salt, predictedAddress);
  }

  function _getAdOwner(uint _idx) internal view returns (address) {
      (address owner,,,,,,,,,) = instance.ads(_idx);
      return owner;
  }

  /// wrap mints an NFT if the ad unit's ownership has been transferred to the
  /// precomputed escrow address.
  function wrap(uint _idx, address _owner) external {
    (bytes32 salt, address precomputedWrapper) = precompute(_idx, _owner);

    require(_getAdOwner(_idx) == precomputedWrapper, "KetherNFT: owner needs to be the correct precommitted address");

    // Wrapper completes the transfer escrow atomically and self-destructs.
    new Wrapper{salt: salt}(address(instance), _encodeWrapperPayload(_idx));

    require(_getAdOwner(_idx) == address(this), "KetherNFT: owner needs to be KetherNFT after wrap");
    _safeMint(_owner, _idx);
  }

  function unwrap(uint _idx, address _newOwner) external {
    require(_isApprovedOrOwner(_msgSender(), _idx), "KetherNFT: unwrap for sender that is not owner");

    instance.setAdOwner(_idx, _newOwner);
    require(_getAdOwner(_idx) == _newOwner, "KetherNFT: unwrap ownership transfer failed");

    _burn(_idx);
  }

  function _renderNFTImage(uint x, uint y, uint width, uint height) internal pure returns (string memory) {
    return Base64.encode(bytes(abi.encodePacked(
      '<svg width="100" height="100" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"><g>',
      '<rect x="',x.toString(),'" y="',y.toString(),'" width="',width.toString(),'" height="',height.toString(),'" fill="orange"></rect>',
      '</g></svg>')));
  }

  function tokenURI(uint256 tokenId) public view override(ERC721) returns (string memory) {
    require(_exists(tokenId), "KetherNFT: tokenId does not exist");

    (,uint x,uint y,uint width,uint height,,,,,) = instance.ads(tokenId);

    // TODO: return tokenRenderer.tokenURI(this, tokenId);
    return string(
      abi.encodePacked(
        'data:application/json;base64,',
        Base64.encode(bytes(abi.encodePacked(
              '{"name":"Thousand Ether Homepage Ad: ',
              width.toString(), 'x', height.toString(), ' at [', x.toString(), ',', y.toString(), ']',
              '", "description":"This NFT represents an ad unit on https://1000ether.com/, the owner of the NFT controls the content of this ad unit.',
              '", "image": "data:image/svg+xml;base64,',
              _renderNFTImage(x, y, width, height),
              '"}'
        )))
      )
    );

  }

  /// publish is a delegated proxy for KetherHomapage's publish function.
  ///
  /// Publish allows for setting the link, image, and NSFW status for the ad
  /// unit that is identified by the idx which was returned during the buy step.
  /// The link and image must be full web3-recognizeable URLs, such as:
  ///  - bzz://a5c10851ef054c268a2438f10a21f6efe3dc3dcdcc2ea0e6a1a7a38bf8c91e23
  ///  - bzz://mydomain.eth/ad.png
  ///  - https://cdn.mydomain.com/ad.png
  ///  - https://ipfs.io/ipfs/Qme7ss3ARVgxv6rXqVPiikMJ8u2NLgmgszg13pYrDKEoiu
  ///  - ipfs://Qme7ss3ARVgxv6rXqVPiikMJ8u2NLgmgszg13pYrDKEoiu
  /// Images should be valid PNG.
  /// Content-addressable storage links like IPFS are encouraged.
  function publish(uint _idx, string calldata _link, string calldata _image, string calldata _title, bool _NSFW) external {
    require(_isApprovedOrOwner(_msgSender(), _idx), "KetherNFT: publish for sender that is not approved");

    instance.publish(_idx, _link, _image, _title, _NSFW);
  }


  /// adminRecoverTrapped allows us to transfer ownership of ads that were
  /// incorrectly transferred to this contract without an NFT being minted.
  /// This should never happen, but we include this recovery function in case
  /// there is a bug in the DApp that somehow falls into this condition.
  /// Note that this function does *not* give admin any control over properly
  /// minted ads/NFTs.
  function adminRecoverTrapped(uint _idx, address _to) external {
    require(_msgSender() == admin, "KetherNFT: recovery must be done by admin");
    require(!_exists(_idx), "KetherNFT: recovery can only be done on unminted ads");
    require(_getAdOwner(_idx) == address(this), "KetherNFT: ad not held by contract");

    instance.setAdOwner(_idx, _to);
  }

  // TODO: adminTransfer
  // TODO: adminDisableRenderUpgrade
}
