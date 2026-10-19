// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IGambMasterChef} from "../src/interfaces/IGambMasterChef.sol";

/// @title GambLegacyForkTest
/// @notice Invariantes do MasterChef legado contra a BSC real (fork).
/// @dev Roda apenas quando `BSC_RPC_URL` está definido. No CI a variável não
///      existe, então todos os testes são pulados. Use `make fork-test`.
///
///      O contrato legado tem owner renunciado, logo estes valores são
///      imutáveis e podem ser tratados como constantes de integração.
contract GambLegacyForkTest is Test {
    IGambMasterChef internal constant CHEF = IGambMasterChef(0x77c1618248358f92Cb144269790103e67378A550);
    address internal constant GAMB = 0x18CdE546D6Ca4DB3b6E62109addE38ee7B1Dd068;
    address internal constant GAMB_WBNB_LP = 0x62DCE0C4E2df11A1bcB2a718F9F43389d91310D5;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        forked = true;
    }

    modifier onFork() {
        vm.skip(!forked);
        _;
    }

    function test_ownerIsRenounced() public onFork {
        assertEq(CHEF.owner(), address(0), "owner should be renounced");
    }

    function test_emissionIsThreeGambPerBlock() public onFork {
        assertEq(CHEF.gambPerBlock(), 3e18, "emission changed");
        assertEq(CHEF.gamb(), GAMB, "reward token changed");
    }

    function test_poolLengthIsAtLeastThirty() public onFork {
        assertGe(CHEF.poolLength(), 30, "unexpected pool count");
    }

    function test_duplicateGambWbnbPoolsShareTheSameLpToken() public onFork {
        (address lp16, uint256 alloc16,,) = CHEF.poolInfo(16);
        (address lp25, uint256 alloc25,,) = CHEF.poolInfo(25);

        assertEq(lp16, GAMB_WBNB_LP, "pool 16 is not GAMB/WBNB");
        assertEq(lp25, GAMB_WBNB_LP, "pool 25 is not GAMB/WBNB");
        assertTrue(alloc16 != alloc25, "pools must have different weights");
    }

    /// @dev `totalAllocPoint` is a display-only aggregate, not a denominator
    ///      for share/APR math. It is ~2.558e30 today and cannot change while
    ///      the owner is renounced; the audit snapshot rounded it to 2.56e30.
    ///      What matters for integrations is that the legacy pools dominate
    ///      the weight, so comparing against or dividing by this value is a bug.
    function test_totalAllocPointIsEnormousLegacyWeight() public onFork {
        uint256 total = CHEF.totalAllocPoint();
        assertGt(total, 1e30, "legacy pools dominate totalAllocPoint");
        assertLt(total, 1e40, "totalAllocPoint should still be a sane uint");
    }
}
