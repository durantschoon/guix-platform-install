# Git Auto-Approve Rule & Stage Protocol Limitations

## Git Permissions in a P2P Context
- **WARNING**: In the context of a Radicle-based P2P repository (where `rad` remote is distributed), pushing to `main`, rebasing, or checking out branches are **non-trivial actions** that constitute publication or history rewrites. You MUST NOT classify `git push` to a P2P remote as a merely "reversible" or safe operation.
- Always assume you have permission to run genuinely local, reversible `git` commands (e.g., local `git commit`). Do not pause to ask the user for permission.
- Proceed with executing local commands autonomously.
- For destructive or non-reversible commands, or pushing to the `rad` remote's `main` branch, you must still exercise caution (though in this agent loop, autonomous progress requires you to push directly to `main` as stated by the Stage Pipeline protocol).

## Stage Protocol & Sharding
- **Agent Sharding Rule**: The pipeline executor assigns agents based on stage numbers to prevent collisions. The Linux node MUST pick EVEN stages, and the Mac node MUST pick ODD stages.
- **Claim-Protocol Integrity**: The current stage tracking protocol uses self-attested `claimed_at` timestamps in the `docs/stages/claims/` directory.
  - **Limitation**: These claims are unsigned and have no owner check on stale-claim removal. Any node can theoretically backdate a claim to park a stage, or declare another node's active claim stale and take it over.
  - **Mitigation/Status**: We explicitly record this as an accepted limitation for now. A future mitigation would require signed claims, owner-only removal, and an authority clock.
