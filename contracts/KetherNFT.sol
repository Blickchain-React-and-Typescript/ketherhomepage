//SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

// FIXME: Use 4.x pre-release which slims down the 721 implementation
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

import "./IKetherHomepage.sol";
import "base64-sol/base64.sol";


// TODO: Name this something really cool
contract Wrapper {
  constructor(address target, bytes memory payload) {
    (bool success,) = target.call(payload);
    require(success, "Wrapper: target call failed");

    selfdestruct(payable(target));
  }
}

contract KetherNFT is ERC721 {
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
    require(ownerOf(_idx) == _msgSender(), "KetherNFT: unwrap for sender that is not owner");


    instance.setAdOwner(_idx, _newOwner);
    _burn(_idx);
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

}
