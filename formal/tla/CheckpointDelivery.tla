---------------------- MODULE CheckpointDelivery -----------------------
EXTENDS Naturals, FiniteSets, Sequences, TLC

(***************************************************************************
This is the smallest temporal model of a local-first replica persistence boundary:

  durable replica event DB
    -> trusted watermark / macro seal
    -> durable outbox with retry
    -> exact-parent authority head

Cryptography and Merkle hashes are abstracted to authenticated checkpoint
records. A checkpoint digest is its epoch plus canonical event set. The model
checks protocol ordering, crash, loss, retry, and partition behavior; MoonBit
continues to check the pure validators and concrete tree implementation.
***************************************************************************)

CONSTANTS
  Peer1,
  Peer2,
  Authority,
  EventA,
  EventB,
  EventC,
  RequireCompleteBeforeSeal,
  DurableOutbox,
  ExactParent,
  RetryEnabled,
  EnforceOutboxCapacity,
  OutboxCapacity,
  AllowCrash,
  AllowPartition,
  AllowDrop

Peers == {Peer1, Peer2}
Nodes == Peers \cup {Authority}
Events == {EventA, EventB, EventC}
Epochs == 1..2
MaxEpoch == 2

ASSUME /\ Peer1 # Peer2
       /\ Authority \notin Peers
       /\ EventA # EventB
       /\ EventA # EventC
       /\ EventB # EventC
       /\ RequireCompleteBeforeSeal \in BOOLEAN
       /\ DurableOutbox \in BOOLEAN
       /\ ExactParent \in BOOLEAN
       /\ RetryEnabled \in BOOLEAN
       /\ EnforceOutboxCapacity \in BOOLEAN
       /\ OutboxCapacity \in Nat \ {0}
       /\ AllowCrash \in BOOLEAN
       /\ AllowPartition \in BOOLEAN
       /\ AllowDrop \in BOOLEAN

EventEpoch(event) == IF event = EventC THEN 2 ELSE 1
EventOwner(event) == IF event = EventB THEN Peer2 ELSE Peer1

ExpectedEvents(epoch) ==
  {event \in Events : EventEpoch(event) <= epoch}

DigestType == [epoch : 0..MaxEpoch, events : SUBSET Events]
Genesis == [epoch |-> 0, events |-> {}]

CheckpointType ==
  [from : Peers,
   epoch : Epochs,
   parent : DigestType,
   events : SUBSET Events]

EventMessageType == [from : Peers, to : Peers, event : Events]

Digest(checkpoint) ==
  [epoch |-> checkpoint.epoch, events |-> checkpoint.events]

VARIABLES
  accepted,
  headLog,
  durableCheckpoints,
  volatileOutbox,
  durableOutbox,
  eventNetwork,
  checkpointNetwork,
  sentEventMessages,
  sentCheckpoints,
  up,
  crashedOnce,
  partitioned

vars ==
  <<accepted,
    headLog,
    durableCheckpoints,
    volatileOutbox,
    durableOutbox,
    eventNetwork,
    checkpointNetwork,
    sentEventMessages,
    sentCheckpoints,
    up,
    crashedOnce,
    partitioned>>

HeadEpoch(node) ==
  IF Len(headLog[node]) = 0
  THEN 0
  ELSE headLog[node][Len(headLog[node])].epoch

CurrentDigest(node) ==
  IF Len(headLog[node]) = 0
  THEN Genesis
  ELSE Digest(headLog[node][Len(headLog[node])])

AuthorityHas(checkpoint) ==
  \E index \in 1..Len(headLog[Authority]) :
    Digest(headLog[Authority][index]) = Digest(checkpoint)

AvailableOutbox(peer) ==
  volatileOutbox[peer] \cup durableOutbox[peer]

Init ==
  /\ accepted =
       [peer \in Peers |->
         {event \in Events : EventOwner(event) = peer}]
  /\ headLog = [node \in Nodes |-> <<>>]
  /\ durableCheckpoints = [peer \in Peers |-> {}]
  /\ volatileOutbox = [peer \in Peers |-> {}]
  /\ durableOutbox = [peer \in Peers |-> {}]
  /\ eventNetwork = {}
  /\ checkpointNetwork = {}
  /\ sentEventMessages = {}
  /\ sentCheckpoints = {}
  /\ up = [node \in Nodes |-> TRUE]
  /\ crashedOnce = [node \in Nodes |-> FALSE]
  /\ partitioned = FALSE

SendEvent(peer, receiver, event) ==
  LET message == [from |-> peer, to |-> receiver, event |-> event]
  IN
    /\ peer # receiver
    /\ up[peer]
    /\ event \in accepted[peer]
    /\ event \notin accepted[receiver]
    /\ message \notin eventNetwork
    /\ RetryEnabled \/ message \notin sentEventMessages
    /\ eventNetwork' = eventNetwork \cup {message}
    /\ sentEventMessages' = sentEventMessages \cup {message}
    /\ UNCHANGED
         <<accepted,
           headLog,
           durableCheckpoints,
           volatileOutbox,
           durableOutbox,
           checkpointNetwork,
           sentCheckpoints,
           up,
           crashedOnce,
           partitioned>>

DeliverEvent(message) ==
  /\ message \in eventNetwork
  /\ ~partitioned
  /\ up[message.to]
  /\ accepted' =
       [accepted EXCEPT ![message.to] = @ \cup {message.event}]
  /\ eventNetwork' = eventNetwork \ {message}
  /\ UNCHANGED
       <<headLog,
         durableCheckpoints,
         volatileOutbox,
         durableOutbox,
         checkpointNetwork,
         sentEventMessages,
         sentCheckpoints,
         up,
         crashedOnce,
         partitioned>>

DropEvent(message) ==
  /\ AllowDrop
  /\ message \in eventNetwork
  /\ eventNetwork' = eventNetwork \ {message}
  /\ UNCHANGED
       <<accepted,
         headLog,
         durableCheckpoints,
         volatileOutbox,
         durableOutbox,
         checkpointNetwork,
         sentEventMessages,
         sentCheckpoints,
         up,
         crashedOnce,
         partitioned>>

SealNextCheckpoint(peer) ==
  LET epoch == HeadEpoch(peer) + 1
      checkpoint ==
        [from |-> peer,
         epoch |-> epoch,
         parent |-> CurrentDigest(peer),
         events |-> accepted[peer] \cap ExpectedEvents(epoch)]
  IN
    /\ up[peer]
    /\ epoch \in Epochs
    /\ (~RequireCompleteBeforeSeal \/
        ExpectedEvents(epoch) \subseteq accepted[peer])
    /\ (~EnforceOutboxCapacity \/
        Cardinality(AvailableOutbox(peer)) < OutboxCapacity)
    /\ headLog' =
         [headLog EXCEPT ![peer] = Append(@, checkpoint)]
    /\ durableCheckpoints' =
         [durableCheckpoints EXCEPT ![peer] = @ \cup {checkpoint}]
    /\ volatileOutbox' =
         [volatileOutbox EXCEPT ![peer] = @ \cup {checkpoint}]
    /\ durableOutbox' =
         IF DurableOutbox
         THEN [durableOutbox EXCEPT ![peer] = @ \cup {checkpoint}]
         ELSE durableOutbox
    /\ UNCHANGED
         <<accepted,
           eventNetwork,
           checkpointNetwork,
           sentEventMessages,
           sentCheckpoints,
           up,
           crashedOnce,
           partitioned>>

SendCheckpoint(peer, checkpoint) ==
  /\ up[peer]
  /\ checkpoint \in AvailableOutbox(peer)
  /\ checkpoint \notin checkpointNetwork
  /\ RetryEnabled \/ checkpoint \notin sentCheckpoints
  /\ checkpointNetwork' = checkpointNetwork \cup {checkpoint}
  /\ sentCheckpoints' = sentCheckpoints \cup {checkpoint}
  /\ UNCHANGED
       <<accepted,
         headLog,
         durableCheckpoints,
         volatileOutbox,
         durableOutbox,
         eventNetwork,
         sentEventMessages,
         up,
         crashedOnce,
         partitioned>>

ReceiveCheckpoint(checkpoint) ==
  LET duplicate == AuthorityHas(checkpoint)
      exactNext ==
        /\ checkpoint.epoch = HeadEpoch(Authority) + 1
        /\ checkpoint.parent = CurrentDigest(Authority)
      acceptedByPolicy ==
        duplicate \/
        IF ExactParent
        THEN exactNext
        ELSE checkpoint.epoch > HeadEpoch(Authority)
  IN
    /\ checkpoint \in checkpointNetwork
    /\ up[Authority]
    /\ ~partitioned
    /\ acceptedByPolicy
    /\ headLog' =
         IF duplicate
         THEN headLog
         ELSE [headLog EXCEPT ![Authority] = Append(@, checkpoint)]
    /\ checkpointNetwork' = checkpointNetwork \ {checkpoint}
    /\ volatileOutbox' =
         [volatileOutbox EXCEPT ![checkpoint.from] = @ \ {checkpoint}]
    /\ durableOutbox' =
         [durableOutbox EXCEPT ![checkpoint.from] = @ \ {checkpoint}]
    /\ UNCHANGED
         <<accepted,
           durableCheckpoints,
           eventNetwork,
           sentEventMessages,
           sentCheckpoints,
           up,
           crashedOnce,
           partitioned>>

DropCheckpoint(checkpoint) ==
  /\ AllowDrop
  /\ checkpoint \in checkpointNetwork
  /\ checkpointNetwork' = checkpointNetwork \ {checkpoint}
  /\ UNCHANGED
       <<accepted,
         headLog,
         durableCheckpoints,
         volatileOutbox,
         durableOutbox,
         eventNetwork,
         sentEventMessages,
         sentCheckpoints,
         up,
         crashedOnce,
         partitioned>>

Crash(peer) ==
  /\ AllowCrash
  /\ up[peer]
  /\ ~crashedOnce[peer]
  /\ up' = [up EXCEPT ![peer] = FALSE]
  /\ crashedOnce' = [crashedOnce EXCEPT ![peer] = TRUE]
  /\ volatileOutbox' = [volatileOutbox EXCEPT ![peer] = {}]
  /\ UNCHANGED
       <<accepted,
         headLog,
         durableCheckpoints,
         durableOutbox,
         eventNetwork,
         checkpointNetwork,
         sentEventMessages,
         sentCheckpoints,
         partitioned>>

Restart(peer) ==
  /\ ~up[peer]
  /\ up' = [up EXCEPT ![peer] = TRUE]
  /\ UNCHANGED
       <<accepted,
         headLog,
         durableCheckpoints,
         volatileOutbox,
         durableOutbox,
         eventNetwork,
         checkpointNetwork,
         sentEventMessages,
         sentCheckpoints,
         crashedOnce,
         partitioned>>

Partition ==
  /\ AllowPartition
  /\ ~partitioned
  /\ partitioned' = TRUE
  /\ UNCHANGED
       <<accepted,
         headLog,
         durableCheckpoints,
         volatileOutbox,
         durableOutbox,
         eventNetwork,
         checkpointNetwork,
         sentEventMessages,
         sentCheckpoints,
         up,
         crashedOnce>>

Heal ==
  /\ partitioned
  /\ partitioned' = FALSE
  /\ UNCHANGED
       <<accepted,
         headLog,
         durableCheckpoints,
         volatileOutbox,
         durableOutbox,
         eventNetwork,
         checkpointNetwork,
         sentEventMessages,
         sentCheckpoints,
         up,
         crashedOnce>>

SendSomeEvent ==
  \E peer, receiver \in Peers, event \in Events :
    SendEvent(peer, receiver, event)

DeliverSomeEvent ==
  \E message \in eventNetwork : DeliverEvent(message)

DropSomeEvent ==
  \E message \in eventNetwork : DropEvent(message)

SealSomeCheckpoint ==
  \E peer \in Peers : SealNextCheckpoint(peer)

SendSomeCheckpoint ==
  \E peer \in Peers, checkpoint \in CheckpointType :
    SendCheckpoint(peer, checkpoint)

IsOldestAvailable(peer, checkpoint) ==
  /\ checkpoint \in AvailableOutbox(peer)
  /\ \A other \in AvailableOutbox(peer) :
       checkpoint.epoch <= other.epoch

SendSomeOldestCheckpoint ==
  \E peer \in Peers, checkpoint \in CheckpointType :
    /\ IsOldestAvailable(peer, checkpoint)
    /\ SendCheckpoint(peer, checkpoint)

ReceiveSomeCheckpoint ==
  \E checkpoint \in checkpointNetwork : ReceiveCheckpoint(checkpoint)

DropSomeCheckpoint ==
  \E checkpoint \in checkpointNetwork : DropCheckpoint(checkpoint)

CrashSomePeer == \E peer \in Peers : Crash(peer)
RestartSomePeer == \E peer \in Peers : Restart(peer)

Next ==
  \/ SendSomeEvent
  \/ DeliverSomeEvent
  \/ DropSomeEvent
  \/ SealSomeCheckpoint
  \/ SendSomeCheckpoint
  \/ ReceiveSomeCheckpoint
  \/ DropSomeCheckpoint
  \/ CrashSomePeer
  \/ RestartSomePeer
  \/ Partition
  \/ Heal

Fairness ==
  /\ SF_vars(SendSomeEvent)
  /\ SF_vars(DeliverSomeEvent)
  /\ WF_vars(SealSomeCheckpoint)
  /\ SF_vars(SendSomeOldestCheckpoint)
  /\ SF_vars(ReceiveSomeCheckpoint)
  /\ WF_vars(RestartSomePeer)
  /\ WF_vars(Heal)

Spec == Init /\ [][Next]_vars /\ Fairness

TypeOK ==
  /\ accepted \in [Peers -> SUBSET Events]
  /\ \A node \in Nodes : headLog[node] \in Seq(CheckpointType)
  /\ durableCheckpoints \in [Peers -> SUBSET CheckpointType]
  /\ volatileOutbox \in [Peers -> SUBSET CheckpointType]
  /\ durableOutbox \in [Peers -> SUBSET CheckpointType]
  /\ eventNetwork \subseteq EventMessageType
  /\ checkpointNetwork \subseteq CheckpointType
  /\ sentEventMessages \subseteq EventMessageType
  /\ sentCheckpoints \subseteq CheckpointType
  /\ up \in [Nodes -> BOOLEAN]
  /\ crashedOnce \in [Nodes -> BOOLEAN]
  /\ partitioned \in BOOLEAN

CheckpointCompleteness ==
  \A peer \in Peers :
    \A checkpoint \in durableCheckpoints[peer] :
      checkpoint.events = ExpectedEvents(checkpoint.epoch)

CheckpointAgreement ==
  \A leftPeer, rightPeer \in Peers :
    \A left \in durableCheckpoints[leftPeer] :
      \A right \in durableCheckpoints[rightPeer] :
        left.epoch = right.epoch => Digest(left) = Digest(right)

IsExactChain(log) ==
  /\ \A index \in 1..Len(log) : log[index].epoch = index
  /\ (Len(log) = 0 \/ log[1].parent = Genesis)
  /\ \A index \in 2..Len(log) :
       log[index].parent = Digest(log[index - 1])

HeadLogsAreExactChains ==
  \A node \in Nodes : IsExactChain(headLog[node])

AcceptedEventsSurviveCrash ==
  \A event \in Events : event \in accepted[EventOwner(event)]

NoLostSealedCheckpoint ==
  \A peer \in Peers :
    \A checkpoint \in durableCheckpoints[peer] :
      \/ AuthorityHas(checkpoint)
      \/ checkpoint \in volatileOutbox[peer]
      \/ checkpoint \in durableOutbox[peer]
      \/ checkpoint \in checkpointNetwork

OutboxWithinCapacity ==
  \A peer \in Peers :
    Cardinality(AvailableOutbox(peer)) <= OutboxCapacity

AuthorityAcceptsOnlyCreatedCheckpoints ==
  \A index \in 1..Len(headLog[Authority]) :
    \E peer \in Peers :
      headLog[Authority][index] \in durableCheckpoints[peer]

AuthorityEventuallyFinalizes ==
  <> (HeadEpoch(Authority) = MaxEpoch)

AllNodesUp == \A node \in Nodes : up[node]

StableNetworkLeadsToFinality ==
  (<>[] (~partitioned /\ AllNodesUp)) => AuthorityEventuallyFinalizes

=============================================================================
