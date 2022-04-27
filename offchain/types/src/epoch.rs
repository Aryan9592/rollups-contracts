use crate::accumulating_epoch::AccumulatingEpoch;
use crate::finalized_epoch::FinalizedEpochs;
use crate::sealed_epoch::{EpochWithClaims, SealedEpochState};
use crate::FoldableError;
use anyhow::{anyhow, Context, Error};
use async_trait::async_trait;
use contracts::rollups_facet::*;
use ethers::{
    prelude::EthEvent,
    providers::Middleware,
    types::{Address, U256},
};
use state_fold::{
    utils as fold_utils, FoldMiddleware, Foldable, StateFoldEnvironment,
    SyncMiddleware,
};
use state_fold_types::{ethers, Block};
use std::sync::Arc;

#[derive(Clone, Debug)]
pub enum ContractPhase {
    InputAccumulation {},
    AwaitingConsensus {
        sealed_epoch: SealedEpochState,
        round_start: U256,
    },
    AwaitingDispute {
        sealed_epoch: EpochWithClaims,
    },
}

#[derive(Clone, Debug)]
pub struct EpochState {
    pub initial_epoch: U256,
    pub current_phase: ContractPhase,
    pub finalized_epochs: FinalizedEpochs,
    pub current_epoch: AccumulatingEpoch,
    /// Timestamp of last contract phase change
    pub phase_change_timestamp: Option<U256>,
    dapp_contract_address: Address,
}

/// Epoch StateActor Delegate, which implements `sync` and `fold`.
/// It uses the subdelegates to extracts the raw state from blockchain
/// emitted events
#[async_trait]
impl Foldable for EpochState {
    type InitialState = (Address, U256);
    type Error = FoldableError;
    type UserData = ();

    async fn sync<M: Middleware + 'static>(
        initial_state: &Self::InitialState,
        block: &Block,
        env: &StateFoldEnvironment<M, Self::UserData>,
        access: Arc<SyncMiddleware<M>>,
    ) -> Result<Self, Self::Error> {
        let (dapp_contract_address, initial_epoch) = *(initial_state);

        let middleware = access.get_inner();
        let contract =
            RollupsFacet::new(dapp_contract_address, Arc::clone(&middleware));

        // retrieve list of finalized epochs from FinalizedEpochFoldDelegate
        let finalized_epochs = FinalizedEpochs::get_state_for_block(
            &(dapp_contract_address, initial_epoch),
            block,
            env,
        )
        .await
        .context("Finalized epoch state fold error")?
        .state;

        // The index of next epoch is the number of finalized epochs
        let next_epoch = finalized_epochs.next_epoch();

        // Retrieve events emitted by the blockchain on phase changes
        let phase_change_events = contract
            .phase_change_filter()
            .query_with_meta()
            .await
            .context("Error querying for rollups phase change")?;

        let phase_change_timestamp = {
            match phase_change_events.last() {
                None => None,
                Some((_, meta)) => Some(
                    middleware
                        .get_block(meta.block_hash)
                        .await
                        .map_err(|e| FoldableError::from(Error::from(e)))?
                        .context("Block not found")?
                        .timestamp,
                ),
            }
        };

        // Define the current_phase and current_epoch  based on the last
        // phase_change event
        let (current_phase, current_epoch) = match phase_change_events.last() {
            // InputAccumulation
            // either accumulating inputs or sealed epoch with no claims/new inputs
            Some((PhaseChangeFilter { new_phase: 0 }, _)) | None => {
                let current_epoch = AccumulatingEpoch::get_state_for_block(
                    &(dapp_contract_address, next_epoch),
                    block,
                    env,
                )
                .await?
                .state;
                (ContractPhase::InputAccumulation {}, current_epoch)
            }

            // AwaitingConsensus
            // can be SealedEpochNoClaims or SealedEpochWithClaims
            Some((PhaseChangeFilter { new_phase: 1 }, _)) => {
                let sealed_epoch = SealedEpochState::get_state_for_block(
                    &(dapp_contract_address, next_epoch),
                    block,
                    env,
                )
                .await?
                .state;

                let current_epoch = AccumulatingEpoch::get_state_for_block(
                    &(dapp_contract_address, next_epoch + 1u64),
                    block,
                    env,
                )
                .await?
                .state;

                // Unwrap is safe because, a phase change event guarantees
                // a phase change timestamp
                let round_start = phase_change_timestamp.unwrap();

                (
                    ContractPhase::AwaitingConsensus {
                        sealed_epoch,
                        round_start,
                    },
                    current_epoch,
                )
            }

            // AwaitingDispute
            Some((PhaseChangeFilter { new_phase: 2 }, _)) => {
                let sealed_epoch = SealedEpochState::get_state_for_block(
                    &(dapp_contract_address, next_epoch),
                    block,
                    env,
                )
                .await?
                .state;

                let current_epoch = AccumulatingEpoch::get_state_for_block(
                    &(dapp_contract_address, next_epoch + 1u64),
                    block,
                    env,
                )
                .await?
                .state;

                (
                    ContractPhase::AwaitingDispute {
                        sealed_epoch: match sealed_epoch {
                            // If there are no claims then the contract can't
                            // be in AwaitingDispute phase
                            SealedEpochState::SealedEpochNoClaims {
                                sealed_epoch,
                            } => {
                                return Err(anyhow!(
                                    "Illegal state for AwaitingDispute: {:?}",
                                    sealed_epoch
                                )
                                .into());
                            }
                            SealedEpochState::SealedEpochWithClaims {
                                claimed_epoch,
                            } => claimed_epoch,
                        },
                    },
                    current_epoch,
                )
            }

            // Err
            Some((PhaseChangeFilter { new_phase }, _)) => {
                return Err(anyhow!(
                    "Could not convert new_phase `{}` to PhaseState",
                    new_phase
                )
                .into());
            }
        };

        Ok(EpochState {
            current_phase,
            phase_change_timestamp,
            initial_epoch,
            finalized_epochs,
            current_epoch,
            dapp_contract_address,
        })
    }

    async fn fold<M: Middleware + 'static>(
        previous_state: &Self,
        block: &Block,
        env: &StateFoldEnvironment<M, Self::UserData>,
        _access: Arc<FoldMiddleware<M>>,
    ) -> Result<Self, Self::Error> {
        let dapp_contract_address = previous_state.dapp_contract_address;
        // Check if there was (possibly) some log emited on this block.
        if !(fold_utils::contains_address(
            &block.logs_bloom,
            &dapp_contract_address,
        ) && fold_utils::contains_topic(
            &block.logs_bloom,
            &PhaseChangeFilter::signature(),
        )) {
            // Current phase has not changed, but we need to update the
            // sub-states.
            let current_epoch = AccumulatingEpoch::get_state_for_block(
                &(
                    dapp_contract_address,
                    previous_state.current_epoch.epoch_number,
                ),
                block,
                env,
            )
            .await?
            .state;

            let current_phase = match &previous_state.current_phase {
                ContractPhase::InputAccumulation {} => {
                    ContractPhase::InputAccumulation {}
                }

                ContractPhase::AwaitingConsensus {
                    sealed_epoch,
                    round_start,
                } => {
                    let sealed_epoch = SealedEpochState::get_state_for_block(
                        &(dapp_contract_address, sealed_epoch.epoch_number()),
                        block,
                        env,
                    )
                    .await?
                    .state;

                    ContractPhase::AwaitingConsensus {
                        sealed_epoch,
                        round_start: *round_start,
                    }
                }

                ContractPhase::AwaitingDispute { sealed_epoch } => {
                    let sealed_epoch = SealedEpochState::get_state_for_block(
                        &(dapp_contract_address, sealed_epoch.epoch_number),
                        block,
                        env,
                    )
                    .await?
                    .state;

                    ContractPhase::AwaitingDispute {
                        sealed_epoch: match sealed_epoch {
                            SealedEpochState::SealedEpochNoClaims {
                                sealed_epoch,
                            } => {
                                return Err(anyhow!(
                                    "Illegal state for AwaitingDispute: {:?}",
                                    sealed_epoch
                                )
                                .into());
                            }
                            SealedEpochState::SealedEpochWithClaims {
                                claimed_epoch,
                            } => claimed_epoch,
                        },
                    }
                }
            };

            return Ok(EpochState {
                current_phase,
                current_epoch,
                phase_change_timestamp: previous_state.phase_change_timestamp,
                initial_epoch: previous_state.initial_epoch,
                finalized_epochs: previous_state.finalized_epochs.clone(),
                dapp_contract_address,
            });
        }

        let middleware = env.inner_middleware();
        let contract = RollupsFacet::new(dapp_contract_address, middleware);

        let finalized_epochs = FinalizedEpochs::get_state_for_block(
            &(dapp_contract_address, previous_state.initial_epoch),
            block,
            env,
        )
        .await?
        .state;

        let next_epoch = finalized_epochs.next_epoch();

        let phase_change_events = contract
            .phase_change_filter()
            .query()
            .await
            .context("Error querying for rollups phase change")?;

        let (current_phase, current_epoch) = match phase_change_events.last() {
            // InputAccumulation
            Some(PhaseChangeFilter { new_phase: 0 }) | None => {
                let current_epoch = AccumulatingEpoch::get_state_for_block(
                    &(dapp_contract_address, next_epoch),
                    block,
                    env,
                )
                .await?
                .state;
                (ContractPhase::InputAccumulation {}, current_epoch)
            }

            // AwaitingConsensus
            Some(PhaseChangeFilter { new_phase: 1 }) => {
                // If the phase is AwaitingConsensus then there are two epochs
                // not yet finalized. One sealead, which can't receive new
                // inputs and one active, accumulating new inputs
                let sealed_epoch = SealedEpochState::get_state_for_block(
                    &(dapp_contract_address, next_epoch),
                    block,
                    env,
                )
                .await?
                .state;
                let current_epoch = AccumulatingEpoch::get_state_for_block(
                    &(dapp_contract_address, next_epoch + 1u64),
                    block,
                    env,
                )
                .await?
                .state;

                // Timestamp of when we entered this phase.
                let round_start = block.timestamp;

                (
                    ContractPhase::AwaitingConsensus {
                        sealed_epoch,
                        round_start,
                    },
                    current_epoch,
                )
            }

            // AwaitingDispute
            Some(PhaseChangeFilter { new_phase: 2 }) => {
                // If the phase is AwaitingDispute then there are two epochs
                // not yet finalized. One sealead, which can't receive new
                // inputs and one active, accumulating new inputs
                let sealed_epoch = SealedEpochState::get_state_for_block(
                    &(dapp_contract_address, next_epoch),
                    block,
                    env,
                )
                .await?
                .state;

                let current_epoch = AccumulatingEpoch::get_state_for_block(
                    &(dapp_contract_address, next_epoch + 1u64),
                    block,
                    env,
                )
                .await?
                .state;

                (
                    ContractPhase::AwaitingDispute {
                        sealed_epoch: match sealed_epoch {
                            SealedEpochState::SealedEpochNoClaims {
                                sealed_epoch,
                            } => {
                                return Err(anyhow!(
                                    "Illegal state for AwaitingDispute: {:?}",
                                    sealed_epoch
                                )
                                .into());
                            }
                            SealedEpochState::SealedEpochWithClaims {
                                claimed_epoch,
                            } => claimed_epoch,
                        },
                    },
                    current_epoch,
                )
            }

            // Err
            Some(PhaseChangeFilter { new_phase }) => {
                return Err(anyhow!(
                    "Could not convert new_phase `{}` to PhaseState",
                    new_phase
                )
                .into());
            }
        };

        let phase_change_timestamp = if phase_change_events.is_empty() {
            previous_state.phase_change_timestamp
        } else {
            Some(block.timestamp)
        };

        Ok(EpochState {
            current_phase,
            current_epoch,
            phase_change_timestamp,
            initial_epoch: previous_state.initial_epoch,
            finalized_epochs,
            dapp_contract_address,
        })
    }
}