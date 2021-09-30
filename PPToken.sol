// SPDX-License-Identifier: MIT

pragma solidity ^0.6.2;

import "./libraries/SafeMath.sol";
import "./libraries/IterableMapping.sol";
import "./Ownable.sol";
import "./ERC20.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Factory.sol";

/**
    @title Pool Party token
    @author kefas; forked TIKU token (which uses TIKI protocol)
 */
contract PPToken is ERC20, Ownable {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapV2Router;
    address public immutable uniswapV2Pair; 

    address public LSDFundAddress;

    uint256 public totalSentToLSDFund;

    bool public isInPresaleState;

    bool public isPairCreated;

    bool private swapping;

    address public liquidityWallet;

    uint256 public maxSellTransactionAmount = 1000000 * (10**18); // 1 Million PP
    uint256 public swapTokensAtAmount = 200000 * (10**18); // 200k PP

    uint256 public immutable liquidityFee;
    uint256 public immutable LSDFundFee;
    uint256 public immutable totalFees;

    // sells have fees of 20% - 15 * 1.33 = ~20
    uint256 public immutable sellFeeIncreaseFactor = 1333; 

    // exlcude from fees and max transaction amount
    mapping (address => bool) private _isExcludedFromFees;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping (address => bool) public automatedMarketMakerPairs;

    event UpdateUniswapV2Router(address indexed newAddress, address indexed oldAddress);

    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    event LiquidityWalletUpdated(address indexed newLiquidityWallet, address indexed oldLiquidityWallet);

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 bnbReceived,
        uint256 tokensIntoLiqudity
    );

    event SendToLSDFund (
        uint256 tokensSwapped,
        uint256 amount
    );
    
    event LSDFundAddressUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );

    constructor() public ERC20("Pool Party", "PP") {
        uint256 _liquidityFee = 4;
        uint256 _LSDFundFee = 11;

        liquidityFee = _liquidityFee;
        LSDFundFee = _LSDFundFee;
        totalFees = _liquidityFee.add(_LSDFundFee);

    	liquidityWallet = owner();
    	
    	isInPresaleState = true;
    	isPairCreated = false;
    	
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        // Creates a pancakeswap pair for PP-WBNB
        address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());

        uniswapV2Router = _uniswapV2Router;
        uniswapV2Pair = _uniswapV2Pair;

        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);       

        // exclude from paying fees or having max transaction amount
        excludeFromFees(liquidityWallet, true);
        excludeFromFees(address(this), true);
        excludeFromFees(LSDFundAddress, true);

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(owner(), 1000000000 * (10**18));
    }

    receive() external payable {
  	}

    function updateUniswapV2Router(address newAddress) public onlyOwner {
        require(newAddress != address(uniswapV2Router), "PP Token: The router already has that address.");
        emit UpdateUniswapV2Router(newAddress, address(uniswapV2Router));
        uniswapV2Router = IUniswapV2Router02(newAddress);
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(_isExcludedFromFees[account] != excluded, "PP Token: Account is already the value of 'excluded'.");
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(address[] calldata accounts, bool excluded) public onlyOwner {
        for(uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    function setAutomatedMarketMakerPair(address pair, bool value) public onlyOwner {
        require(pair != uniswapV2Pair, "PP Token: The PCS pair cannot be removed from automatedMarketMakerPairs!");        
        _setAutomatedMarketMakerPair(pair, value);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(automatedMarketMakerPairs[pair] != value, "PP Token: Automated market maker pair is already set to that value.");
        automatedMarketMakerPairs[pair] = value;

        emit SetAutomatedMarketMakerPair(pair, value);
    }


    function updateLiquidityWallet(address newLiquidityWallet) public onlyOwner {
        require(newLiquidityWallet != liquidityWallet, "PP Token: The liquidity wallet is already this address.");
        excludeFromFees(newLiquidityWallet, true);
        emit LiquidityWalletUpdated(newLiquidityWallet, liquidityWallet);
        liquidityWallet = newLiquidityWallet;
    }

    function isExcludedFromFees(address account) public view returns(bool) {
        return _isExcludedFromFees[account];
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        if(isInPresaleState) {
             super._transfer(from, to, amount);
             return;
        }

        if(amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        if( 
        	!swapping &&
            automatedMarketMakerPairs[to] && // sells only by detecting transfer to automated market maker pair
        	from != address(uniswapV2Router) && //router -> pair is removing liquidity which shouldn't have max
            !_isExcludedFromFees[to] //no max for those excluded from fees
        ) {
            require(amount <= maxSellTransactionAmount, "Sell transfer amount exceeds the maxSellTransactionAmount.");
        }

		uint256 contractTokenBalance = balanceOf(address(this));
        
        bool canSwap = contractTokenBalance >= swapTokensAtAmount;

        if(
            canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from] &&
            from != liquidityWallet &&
            to != liquidityWallet
        ) {
            swapping = true;

            uint256 swapTokens = contractTokenBalance.mul(liquidityFee).div(totalFees);
            swapAndLiquify(swapTokens);

            uint256 LSDTokens = balanceOf(address(this));
            swapAndSendToLSDFund(LSDTokens);

            swapping = false;
        }

        bool takeFee = !swapping; 

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if(_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if(takeFee) {
        	uint256 fees = amount.mul(totalFees).div(100);

            // if selling, multiply by 1.333 = ~20% fee
            if(automatedMarketMakerPairs[to]) {
                fees = fees.mul(sellFeeIncreaseFactor).div(1000);
            }

        	amount = amount.sub(fees);

            super._transfer(from, address(this), fees);
        }

        super._transfer(from, to, amount);

    }

    function swapAndLiquify(uint256 _amount) private {
        // split the contract balance into halves
        uint256 half = _amount.div(2);
        uint256 otherHalf = _amount.sub(half);

        // capture the contract's current BNB balance.
        // this is so that we can capture exactly the amount of BNB that the
        // swap creates, and not make the liquidity event include any BNB that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap _amount for BNB
        swapTokensForBnb(half); // <- this breaks the ETH -> PP swap when swap+liquify is triggered

        // how much BNB did we just swap into
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to uniswap
        addLiquidity(otherHalf, newBalance);
        
        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function swapTokensForBnb(uint256 tokenAmount) private {
        // generate the uniswap pair path of PP -> WBNB 
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of BNB
            path,
            address(this),
            block.timestamp
        );
        
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // add the liquidity
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            liquidityWallet,
            block.timestamp
        );
        
    }
    
    function swapAndSendToLSDFund(uint256 _amount) private {
        require(LSDFundAddress != address(0), "PP Token: LSD Fund address is not set.");
        swapTokensForBnb(_amount);
        // Sends whole balance to LSD fund 
        uint256 bnbToLSDFund = address(this).balance;
        (bool sent,) = LSDFundAddress.call{value: bnbToLSDFund}("");
        if (sent) {
            totalSentToLSDFund = totalSentToLSDFund.add(bnbToLSDFund);
            emit SendToLSDFund(_amount, bnbToLSDFund);
        }
    }
    
    function updateLSDFundAddress(address _newAddress) external onlyOwner {
        require(_newAddress != LSDFundAddress, "PP Token: Current LSD Fund address and the new address are the same.");
        require(_newAddress != address(0), "PP Token: LSD Fund address can not be set to the 0x0 address!");
        address oldAddress = LSDFundAddress;
        LSDFundAddress = _newAddress;
        excludeFromFees(oldAddress, false);
        excludeFromFees(_newAddress, true);
        emit LSDFundAddressUpdated(oldAddress, _newAddress);
    }
    
    function enterAfterPresaleState () external onlyOwner {
        require(isInPresaleState, "PP Token: The contract is already in the AfterPresale state, calling this function has no meaning!");
        isInPresaleState = false;
    }
}
