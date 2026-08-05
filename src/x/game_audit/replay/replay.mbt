///|
fn append_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(value.length().to_string())
  buffer.write_char(':')
  buffer.write_string(value)
}

///|
pub fn serialize_asset_effect(effect : AssetEffect) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "asset-effect-v1")
  match effect {
    Create(asset_id~, recipient_id~, item_type~, quantity~, output_index~) => {
      buffer.write_char('C')
      append_field(buffer, asset_id)
      append_field(buffer, recipient_id)
      append_field(buffer, item_type)
      append_field(buffer, quantity.to_string())
      append_field(buffer, output_index.to_string())
    }
    Transfer(asset_id~, from_owner~, to_owner~, expected_version~) => {
      buffer.write_char('T')
      append_field(buffer, asset_id)
      append_field(buffer, from_owner)
      append_field(buffer, to_owner)
      append_field(buffer, expected_version.to_string())
    }
  }
  buffer.to_string()
}

///|
fn AssetEffect::asset_id(self : AssetEffect) -> String {
  match self {
    Create(asset_id~, ..) => asset_id
    Transfer(asset_id~, ..) => asset_id
  }
}

///|
pub fn validate_asset_effect(effect : AssetEffect) -> AssetEffectValidation {
  match effect {
    Create(asset_id~, recipient_id~, item_type~, quantity~, output_index~) => {
      if asset_id == "" {
        return MissingAssetId
      }
      if recipient_id == "" {
        return MissingRecipient
      }
      if item_type == "" {
        return MissingItemType
      }
      if quantity <= 0 {
        return InvalidQuantity
      }
      if output_index < 0 {
        return InvalidOutputIndex
      }
      EffectValid
    }
    Transfer(asset_id~, from_owner~, to_owner~, expected_version~) => {
      if asset_id == "" {
        return MissingAssetId
      }
      if from_owner == "" || to_owner == "" {
        return MissingOwner
      }
      if from_owner == to_owner {
        return SameOwner
      }
      if expected_version < 0 {
        return InvalidExpectedVersion
      }
      EffectValid
    }
  }
}

///|
/// Encode an asset-effect declaration in the generic durable Event envelope.
pub fn make_asset_effect_event(
  peer~ : @types.PeerId,
  counter~ : Int,
  lamport~ : Int,
  deps~ : Array[@types.EventId],
  effect~ : AssetEffect,
) -> @types.Event {
  {
    id: { peer, counter },
    deps,
    lamport,
    op: @types.RowOp::Insert(
      tbl="converge.asset-effect.v1",
      row_id=effect.asset_id(),
      values=[("effect", @types.Value::Str(serialize_asset_effect(effect)))],
    ),
  }
}

///|
pub fn CanonicalAssetKernel::new(
  hasher : &@bft.Hasher,
  effect_author~ : @bft.PublicKey,
) -> CanonicalAssetKernel {
  let buffer = StringBuilder::new()
  append_field(buffer, "canonical-asset-kernel-v1")
  append_field(buffer, effect_author.0)
  CanonicalAssetKernel::{
    manifest: hasher.hash_string(buffer.to_string()),
    effect_author,
  }
}

///|
pub impl AssetReplayKernel for CanonicalAssetKernel with fn manifest_digest(
  self : CanonicalAssetKernel,
) -> @bft.Digest {
  self.manifest
}

///|
pub impl AssetReplayKernel for CanonicalAssetKernel with fn replay(
  self : CanonicalAssetKernel,
  source : @bft.AuthenticatedEvent,
  effect : AssetEffect,
) -> Bool {
  let event = source.event()
  if source.author_key() != self.effect_author ||
    event.id.counter < 0 ||
    event.lamport < 0 {
    return false
  }
  match event.op {
    @types.RowOp::Insert(tbl~, row_id~, values~) =>
      tbl == "converge.asset-effect.v1" &&
      row_id == effect.asset_id() &&
      values.length() == 1 &&
      values[0].0 == "effect" &&
      values[0].1 == @types.Value::Str(serialize_asset_effect(effect))
    _ => false
  }
}

///|
pub fn ReplayEngine::new(
  kernel : &AssetReplayKernel,
  session_id~ : String,
) -> ReplayEngine {
  ReplayEngine::{ session: session_id, kernel }
}

///|
pub fn ReplayEngine::replay(
  self : ReplayEngine,
  source : @bft.AuthenticatedEvent,
  effect : AssetEffect,
) -> ReplayResult {
  let session_matches = self.session != "" &&
    source.session_id() == self.session
  let effect_valid = validate_asset_effect(effect) == EffectValid
  let manifest = self.kernel.manifest_digest()
  let manifest_present = manifest.0 != ""
  let kernel_accepted = session_matches &&
    effect_valid &&
    manifest_present &&
    self.kernel.replay(source, effect)
  let allowed = @audit.replayed_effect_allowed(
    source_authenticated=true,
    session_matches~,
    effect_valid~,
    manifest_present~,
    kernel_accepted~,
  )
  if allowed {
    return Replayed(ReplayedAssetEffect::{ source, manifest, effect })
  }
  if !session_matches {
    return Refused(SessionMismatch)
  }
  if !effect_valid {
    return Refused(InvalidEffect)
  }
  if !manifest_present {
    return Refused(InvalidManifest)
  }
  Refused(KernelRejected)
}

///|
pub fn ReplayedAssetEffect::session_id(self : ReplayedAssetEffect) -> String {
  self.source.session_id()
}

///|
pub fn ReplayedAssetEffect::source_digest(
  self : ReplayedAssetEffect,
) -> @bft.Digest {
  self.source.digest()
}

///|
pub fn ReplayedAssetEffect::manifest_digest(
  self : ReplayedAssetEffect,
) -> @bft.Digest {
  self.manifest
}

///|
pub fn ReplayedAssetEffect::effect(self : ReplayedAssetEffect) -> AssetEffect {
  self.effect
}

///|
pub fn ReplayedAssetEffect::matches(
  self : ReplayedAssetEffect,
  session_id~ : String,
  manifest_digest~ : @bft.Digest,
  source_digest~ : @bft.Digest,
  effect~ : AssetEffect,
) -> Bool {
  @audit.source_capability_matches(
    session_matches=self.session_id() == session_id,
    digest_matches=self.source_digest() == source_digest,
  ) &&
  self.manifest == manifest_digest &&
  self.effect == effect
}
