// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseMiddleware} from "./middleware/BaseMiddleware.sol";
import {Subnetworks} from "./extensions/Subnetworks.sol";
import {SelfRegisterOperators} from "./extensions/operators/SelfRegisterOperators.sol";
import {OwnableAccessManager} from "./extensions/managers/access/OwnableAccessManager.sol";
import {KeyManagerAddress} from "./extensions/managers/keys/KeyManagerAddress.sol";
import {ECDSASig} from "./extensions/managers/sigs/ECDSASig.sol";
import {EpochCapture} from "./extensions/managers/capture-timestamps/EpochCapture.sol";
import {EqualStakePower} from "./extensions/managers/stake-powers/EqualStakePower.sol";

contract HyperlaneMiddleware is
    BaseMiddleware,
    Subnetworks,
    SelfRegisterOperators,
    OwnableAccessManager,
    KeyManagerAddress,
    ECDSASig,
    EpochCapture,
    EqualStakePower
{}
