import {defineDocFamily, ProviderDoc} from '@earendil-works/pi-durable';

// Durable Pi session IDs identify the actual conversation for both ordinary generation and
// compaction. A missing grant is local-only, including histories created before this policy.
const PeerGrant = defineDocFamily({kind:'banana.peer-grant',version:1,scope:'session',family:true,
  initial: peer => ({peer}),checkpointWhen:() => true});

export async function grantFreshConversation(owner, conversationId, peer, ctx) {
  if (!peer) return;
  await owner.commit(async tx => {
    const {sessionId} = await tx.doc(ProviderDoc,conversationId);
    // Only the new-conversation entry points call this. A retry cannot restore a revoked grant.
    await tx.doc(PeerGrant,sessionId,peer);
  },ctx);
}

export async function peerAllowed(owner, sessionId, peer, ctx) {
  if (!owner || !sessionId || !peer) return false;
  return (await owner.snapshot(PeerGrant,sessionId,ctx))?.peer === peer;
}

export async function conversationPeerAllowed(owner, conversationId, peer, ctx) {
  if (!peer) return false;
  const state = await owner.snapshot(ProviderDoc,conversationId,ctx);
  return peerAllowed(owner,state?.sessionId,peer,ctx);
}

export async function keepEvidenceOnDevice(owner, conversationId, ctx) {
  const state = await owner.snapshot(ProviderDoc,conversationId,ctx);
  if (!state) return;
  const grant = await owner.snapshot(PeerGrant,state.sessionId,ctx);
  if (grant?.peer) {
    await owner.commit(async tx => {
      (await tx.doc(PeerGrant,state.sessionId,null)).peer = null;
    },ctx);
  }
}
