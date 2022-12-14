// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IArtMarketplaceContract.sol";
import "./IArtCollectibleContract.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./Utils.sol";

/// @custom:security-contact dreamsoftware92@gmail.com
contract ArtMarketplaceContract is
    ReentrancyGuard,
    Ownable,
    IArtMarketplaceContract
{
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    using Utils for string;

    uint256 public constant DEFAULT_COST_OF_PUTTING_FOR_SALE = 0.010 ether;

    Counters.Counter private _marketItemIds;
    Counters.Counter private _tokensSold;
    Counters.Counter private _tokensCanceled;
    address private _artCollectibleAddress;
    uint256 public costOfPuttingForSale = DEFAULT_COST_OF_PUTTING_FOR_SALE;
    // Mapping to prevent the same item being listed twice
    mapping(uint256 => bool) private _hasBeenAddedForSale;
    mapping(uint256 => ArtCollectibleForSale) private _tokensForSale;
    ArtCollectibleForSale[] private _marketHistory;


    function getArtCollectibleAddress()
        public
        view
        onlyOwner
        returns (address)
    {
        return _artCollectibleAddress;
    }

    function setArtCollectibleAddress(address artCollectibleAddress)
        public
        payable
        onlyOwner
    {
        _artCollectibleAddress = artCollectibleAddress;
    }

    function setCostOfPuttingForSale(uint8 _costOfPuttingForSale)
        external
        onlyOwner
    {
        costOfPuttingForSale = _costOfPuttingForSale;
    }

    /**
     * @dev list an item with a `tokenId` for a `price`
     *
     * Requirements:
     * - Only the owner of the `tokenId` can list the item
     * - The `tokenId` can only be listed once
     *
     * Emits a {Transfer} event - transfer the token to this smart contract.
     * Emits a {ArtCollectibleAddedForSale} event
     */
    function putItemForSale(uint256 tokenId, uint256 price)
        external
        payable
        nonReentrant
        OnlyItemOwner(tokenId)
        ItemNotAlreadyAddedForSale(tokenId)
        PriceMustBeAtLeastOneWei(price)
        PriceMustBeEqualToListingPrice(msg.value)
        returns (uint256)
    {

        //send the token to the smart contract
        IERC721(_artCollectibleAddress).transferFrom(msg.sender, address(this), tokenId);
        _marketItemIds.increment();
        uint256 marketItemId = _marketItemIds.current();
        _tokensForSale[tokenId] = ArtCollectibleForSale(
            marketItemId,
            tokenId,
            payable(
                IArtCollectibleContract(_artCollectibleAddress)
                    .getTokenCreatorById(tokenId)
            ),
            payable(msg.sender),
            payable(address(this)),
            price,
            false,
            false
        );
        _hasBeenAddedForSale[tokenId] = true;
        emit ArtCollectibleAddedForSale(marketItemId, tokenId, price);
        return marketItemId;
    }

    /**
     * @dev Cancel a listing of an item with a `tokenId`
     *
     * Requirements:
     * - Only the account that has listed the `tokenId` can delist it
     *
     * Emits a {Transfer} event - transfer the token from this smart contract to the owner.
     * Emits a {ArtCollectibleWithdrawnFromSale} event.
     */
    function withdrawFromSale(uint256 tokenId)
        external
        ItemAlreadyAddedForSale(tokenId)
    {
        //send the token from the smart contract back to the one who listed it
        IERC721(_artCollectibleAddress).transferFrom(address(this), msg.sender, tokenId);
        _tokensCanceled.increment();
        _tokensForSale[tokenId].owner = payable(msg.sender);
        _tokensForSale[tokenId].canceled = true;
        _marketHistory.push(_tokensForSale[tokenId]);
        delete _hasBeenAddedForSale[tokenId];
        delete _tokensForSale[tokenId];
        emit ArtCollectibleWithdrawnFromSale(tokenId);
    }

    /**
     * @dev Buy an item with a `tokenId` and pay the owner and the creator
     *
     * Requirements:
     * - `tokenId` has to be listed
     * - `price` needs to be the same as the value sent by the caller
     *
     * Emits a {Transfer} event - transfer the item from this smart contract to the buyer.
     * Emits an {ArtCollectibleSold} event.
     */
    function buyItem(uint256 tokenId)
        external
        payable
        NotItemOwner(tokenId)
        ItemAlreadyAddedForSale(tokenId)
        PriceMustBeEqualToItemPrice(tokenId, msg.value)
    {
        IArtCollectibleContract.ArtCollectible
            memory token = IArtCollectibleContract(_artCollectibleAddress)
                .getTokenById(tokenId);

        //split up the price between owner and creator
        uint256 royaltyForCreator = token.royalty.mul(msg.value).div(100);
        uint256 remainder = msg.value.sub(royaltyForCreator);
        //send to creator
        (bool isRoyaltySent, ) = _tokensForSale[tokenId].creator.call{value: royaltyForCreator}("");
        require(
            isRoyaltySent,
            "An error ocurred when sending royalty to token creator"
        );
        //send to owner
        (bool isRemainderSent, ) = _tokensForSale[tokenId].seller.call{value: remainder}("");
        require(
            isRemainderSent,
            "An error ocurred when sending remainder to token seller"
        );
        //transfer the token from the smart contract back to the buyer
        IERC721(_artCollectibleAddress).transferFrom(address(this), msg.sender, tokenId);
        _tokensSold.increment();
        _tokensForSale[tokenId].owner = payable(msg.sender);
        _tokensForSale[tokenId].sold = true;
        _marketHistory.push(_tokensForSale[tokenId]);
        delete _hasBeenAddedForSale[tokenId];
        delete _tokensForSale[tokenId];
        emit ArtCollectibleSold(tokenId, msg.sender, msg.value);
    }

    /**
     * @dev Fetch non sold and non canceled market items
     */
    function fetchAvailableMarketItems()
        external
        view
        returns (ArtCollectibleForSale[] memory)
    {
        uint256 itemsCount = _marketItemIds.current();
        uint256 soldItemsCount = _tokensSold.current();
        uint256 canceledItemsCount = _tokensCanceled.current();
        uint256 availableItemsCount = itemsCount -
            soldItemsCount -
            canceledItemsCount;
        ArtCollectibleForSale[]
            memory marketItems = new ArtCollectibleForSale[](
                availableItemsCount
            );
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < itemsCount; i++) {
            ArtCollectibleForSale memory item = _tokensForSale[i + 1];
            if (item.owner != address(0)) continue;
            marketItems[currentIndex] = item;
            currentIndex += 1;
        }
        return marketItems;
    }

    /**
     * @dev Fetch market items that are being listed by the msg.sender
     */
    function fetchSellingMarketItems()
        external
        view
        returns (ArtCollectibleForSale[] memory)
    {
        return _fetchMarketItemsByAddressProperty("seller");
    }

    /**
     * @dev Fetch market items that are owned by the msg.sender
     */
    function fetchOwnedMarketItems()
        public
        view
        returns (ArtCollectibleForSale[] memory)
    {
        return _fetchMarketItemsByAddressProperty("owner");
    }

    /**
     * @dev Allow us to fetch market history
     */
    function fetchMarketHistory()
        public
        view
        returns (ArtCollectibleForSale[] memory)
    {
        return _marketHistory;
    }


    /**
     * @dev Fetches market items according to the its requested address property that
     * can be "owner" or "seller".
     * See original: https://github.com/dabit3/polygon-ethereum-nextjs-marketplace/blob/main/contracts/Market.sol#L121
     */
    function _fetchMarketItemsByAddressProperty(string memory _addressProperty)
        private
        view
        returns (ArtCollectibleForSale[] memory)
    {
        require(
            _addressProperty.compareStrings("seller") ||
                _addressProperty.compareStrings("owner"),
            "Parameter must be 'seller' or 'owner'"
        );
        uint256 totalItemsCount = _marketItemIds.current();
        uint256 itemCount = 0;
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < totalItemsCount; i++) {
            address addressPropertyValue = _addressProperty.compareStrings(
                "seller"
            )
                ? _tokensForSale[i + 1].seller
                : _tokensForSale[i + 1].owner;
            if (addressPropertyValue != msg.sender) continue;
            itemCount += 1;
        }
        ArtCollectibleForSale[] memory items = new ArtCollectibleForSale[](
            itemCount
        );
        for (uint256 i = 0; i < totalItemsCount; i++) {
            ArtCollectibleForSale storage item = _tokensForSale[i + 1];
            address addressPropertyValue = _addressProperty.compareStrings(
                "seller"
            )
                ? item.seller
                : item.owner;
            if (addressPropertyValue != msg.sender) continue;
            items[currentIndex] = item;
            currentIndex += 1;
        }
        return items;
    }

    // Modifiers
    modifier OnlyItemOwner(uint256 tokenId) {
        require(
            ERC721(_artCollectibleAddress).ownerOf(tokenId) == msg.sender,
            "Sender does not own the item"
        );
        _;
    }

    modifier NotItemOwner(uint256 tokenId) {
        require(
            ERC721(_artCollectibleAddress).ownerOf(tokenId) != msg.sender,
            "Sender must not be the token owner"
        );
        _;
    }

    modifier ItemNotAlreadyAddedForSale(uint256 tokenId) {
        require(!_hasBeenAddedForSale[tokenId], "Item already added for sale");
        _;
    }

    modifier ItemAlreadyAddedForSale(uint256 tokenId) {
        require(
            _hasBeenAddedForSale[tokenId],
            "Item hasn't beed added for sale"
        );
        _;
    }

    modifier PriceMustBeEqualToListingPrice(uint256 value) {
        require(
            value == costOfPuttingForSale,
            "Price must be equal to listing price"
        );
        _;
    }

    modifier PriceMustBeEqualToItemPrice(uint256 tokenId, uint256 value) {
        require(
            _tokensForSale[tokenId].price == value,
            "Price must be equal to item price"
        );
        _;
    }

    modifier PriceMustBeAtLeastOneWei(uint256 price) {
        require(price > 0, "Price must be at least 1 wei");
        _;
    }

}