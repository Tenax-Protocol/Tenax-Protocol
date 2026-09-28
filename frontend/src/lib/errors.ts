import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";

/** Plain explanations for the protocol errors a user can run into. */
const MESSAGES: Record<string, string> = {
  InsufficientVotingPower: "You need at least 5,000 veTENAX to forecast. Lock more TENAX or extend your lock.",
  SubmissionClosed: "Submissions for this round are closed. The next round opens at 00:00 UTC.",
  NotCurrentRound: "This round is no longer accepting forecasts.",
  AlreadyCommitted: "You already committed a forecast for this round.",
  TooManyPending: "You have too many forecasts waiting to be scored. Wait for keepers to resolve past rounds.",
  RevealNotOpen: "Reveals open 24 hours after submissions close.",
  RevealClosed: "The reveal window for this round has closed.",
  AlreadyRevealed: "This forecast is already revealed.",
  CommitmentMismatch: "The forecast does not match your commitment. Use the same wallet and forecast key.",
  LockAlreadyExists: "You already have a lock. Increase its amount or extend it instead.",
  LockExpired: "Your lock has expired. Withdraw it first.",
  LockNotExpired: "Your lock has not expired yet.",
  NoVoluntaryBalance: "Only tokens you locked yourself can exit early; rewards stay locked until they unlock.",
  UnlockTimeTooSoon: "Locks last at least one week.",
  UnlockTimeTooLate: "Locks last at most 104 weeks.",
  UnlockTimeNotIncreased: "The new unlock time must be later than the current one, in whole weeks.",
  NotEligible: "This account is not eligible for the season's rewards.",
  AlreadyRegistered: "Already registered for this season.",
  RegistrationNotOpen: "Registration for this season is not open yet.",
  RegistrationClosed: "Registration for this season has closed.",
  SeasonNotClosed: "The season has not closed yet.",
  AlreadyClaimed: "Already claimed.",
  NotRegistered: "You were not registered for this season.",
};

/** A short, readable message for a failed wallet request or contract call. */
export function errorMessage(error: unknown): string {
  if (error instanceof BaseError) {
    if (error.walk((e) => e instanceof UserRejectedRequestError)) return "Request rejected in the wallet.";
    const revert = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName;
      if (name && MESSAGES[name]) return MESSAGES[name];
      if (name) return `The contract rejected the call (${name}).`;
      return revert.reason ?? revert.shortMessage;
    }
    return error.shortMessage;
  }
  return error instanceof Error ? error.message : String(error);
}
