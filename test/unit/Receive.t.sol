pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SenderNotPoolManager} from "src/Doppler.sol";
import {BaseTest} from "test/shared/BaseTest.sol";

contract ReceiveTest is BaseTest {
    function test_receive_RevertsIfSenderNotPoolManager() public {
        vm.expectRevert(SenderNotPoolManager.selector);
        payable(address(hook)).transfer(1 ether);
    }

    function test_receive_ReceivesIfSenderIsPoolManager() public {
        deal(address(manager), 1 ether);
        vm.prank(address(manager));
        payable(address(hook)).transfer(1 ether);
    }
}