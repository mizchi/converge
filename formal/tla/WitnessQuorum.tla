------------------------- MODULE WitnessQuorum -------------------------
EXTENDS Naturals, FiniteSets, TLC

(***************************************************************************
One destination-specific checkpoint witness collection. Cryptographic
verification is abstracted to response.valid; this model checks distinct
roster counting, producer authentication, deadline behavior, and the gate
between a ready collection and authority mutation.
***************************************************************************)

CONSTANTS
  Witness1,
  Witness2,
  Witness3,
  Witness4,
  Intruder,
  RequiredApprovals,
  ProducerSignatureValid,
  EnforceProducerSignature,
  EnforceRoster,
  AllowExpire

Roster == {Witness1, Witness2, Witness3, Witness4}
Actors == Roster \cup {Intruder}
Statuses == {"collecting", "ready", "expired"}
Classifications == {"none", "pending", "invalid"}
ResponseType == [witness : Actors, valid : BOOLEAN]

ASSUME /\ Cardinality(Roster) = 4
       /\ Intruder \notin Roster
       /\ RequiredApprovals \in 1..Cardinality(Roster)
       /\ ProducerSignatureValid \in BOOLEAN
       /\ EnforceProducerSignature \in BOOLEAN
       /\ EnforceRoster \in BOOLEAN
       /\ AllowExpire \in BOOLEAN

VARIABLES
  network,
  acceptedWitnesses,
  status,
  classification,
  receiverAdvanced

vars ==
  <<network,
    acceptedWitnesses,
    status,
    classification,
    receiverAdvanced>>

Init ==
  /\ network = {}
  /\ acceptedWitnesses = {}
  /\ status = "collecting"
  /\ classification = "none"
  /\ receiverAdvanced = FALSE

SendHonestApproval(witness) ==
  LET response == [witness |-> witness, valid |-> TRUE]
  IN
    /\ witness \in Roster
    /\ status = "collecting"
    /\ witness \notin acceptedWitnesses
    /\ response \notin network
    /\ network' = network \cup {response}
    /\ UNCHANGED
         <<acceptedWitnesses, status, classification, receiverAdvanced>>

SendHostileResponse(witness, valid) ==
  LET response == [witness |-> witness, valid |-> valid]
  IN
    /\ witness \in Actors
    /\ response \notin network
    /\ network' = network \cup {response}
    /\ UNCHANGED
         <<acceptedWitnesses, status, classification, receiverAdvanced>>

DeliverResponse(response) ==
  LET rosterAccepted ==
        response.valid /\ (response.witness \in Roster \/ ~EnforceRoster)
      nextAccepted ==
        IF status = "collecting" /\ rosterAccepted
        THEN acceptedWitnesses \cup {response.witness}
        ELSE acceptedWitnesses
      producerAccepted ==
        ProducerSignatureValid \/ ~EnforceProducerSignature
      quorumReached ==
        Cardinality(nextAccepted) >= RequiredApprovals
  IN
    /\ response \in network
    /\ network' = network \ {response}
    /\ acceptedWitnesses' = nextAccepted
    /\ status' =
         IF status = "collecting" /\ producerAccepted /\ quorumReached
         THEN "ready"
         ELSE status
    /\ UNCHANGED <<classification, receiverAdvanced>>

Expire ==
  /\ AllowExpire
  /\ status = "collecting"
  /\ status' = "expired"
  /\ classification' = "pending"
  /\ UNCHANGED <<network, acceptedWitnesses, receiverAdvanced>>

AdvanceReceiver ==
  /\ status = "ready"
  /\ ~receiverAdvanced
  /\ receiverAdvanced' = TRUE
  /\ UNCHANGED <<network, acceptedWitnesses, status, classification>>

SendSomeHonestApproval ==
  \E witness \in Roster : SendHonestApproval(witness)

SendSomeHostileResponse ==
  \E witness \in Actors, valid \in BOOLEAN :
    SendHostileResponse(witness, valid)

DeliverSomeResponse ==
  \E response \in network : DeliverResponse(response)

DeliverSomeHonestResponse ==
  \E response \in network :
    /\ response.valid
    /\ response.witness \in Roster
    /\ response.witness \notin acceptedWitnesses
    /\ DeliverResponse(response)

Next ==
  \/ SendSomeHonestApproval
  \/ SendSomeHostileResponse
  \/ DeliverSomeResponse
  \/ Expire
  \/ AdvanceReceiver

Fairness ==
  /\ SF_vars(SendSomeHonestApproval)
  /\ SF_vars(DeliverSomeResponse)
  /\ SF_vars(DeliverSomeHonestResponse)
  /\ WF_vars(AdvanceReceiver)

Spec == Init /\ [][Next]_vars /\ Fairness

TypeOK ==
  /\ network \subseteq ResponseType
  /\ acceptedWitnesses \subseteq Actors
  /\ status \in Statuses
  /\ classification \in Classifications
  /\ receiverAdvanced \in BOOLEAN

ReadyRequiresAuthenticatedDistinctRosterQuorum ==
  status = "ready" =>
    /\ ProducerSignatureValid
    /\ acceptedWitnesses \subseteq Roster
    /\ Cardinality(acceptedWitnesses) >= RequiredApprovals

ReceiverRequiresReadyCollection == receiverAdvanced => status = "ready"

TimeoutNeverMarksInvalid == classification # "invalid"

ExpiredCollectionNeverAdvances == status = "expired" => ~receiverAdvanced

AllHonestApprovalsEventuallyReady == <>(status = "ready")

=============================================================================
