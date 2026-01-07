# Chapter 12: Case Study: Waiting for Godot — Reflections for Umi

A short but haunting chapter. The deployment army: 40+ people, 24 hours, $100,000, and it still failed. The contrast with Etsy's "deployinator"—an investor pushes a button as a routine demo—is stark.

## The Deployment Army Antipattern

The vignette captures everything wrong with traditional deployments:
- **Massive coordination**: 40+ people across four locations
- **Rigid playbooks**: Row-by-row procedures, no room for adaptation
- **Environment drift**: QA didn't match production (the fatal flaw)
- **Time distortion**: "Lamport clock" vs wall clock—playbook says 11:50pm but it's 1:17am
- **Wasted humanity**: People used as bots, watching graphs for problems that were fixed years ago

> "Using people as if they were bots. Disrupting lives, families, sleep patterns...it was all such a waste."

## What Does This Mean for Umi?

Umi is a library, not a deployment system. But the themes resonate:

### 1. Graceful Transition During Upgrade

When you upgrade application code, what happens to running workers?

**The deployment army approach:**
- Stop everything
- Deploy new code
- Start everything
- Hope it works
- Rollback if it doesn't

**The Umi approach (potential):**
- Deploy new code alongside old
- Supervision tree starts new workers with new code
- Old workers drain and stop
- New workers take over
- If new workers fail, supervision can restart old code (rollback at supervisor level)

This is rolling deployment at the Ractor level. The supervision tree enables it:
- Supervisors don't stop during deployment
- Workers stop, but one at a time (not all at once)
- Circuit breakers and health checks detect problems early
- Escalation signals "something is wrong with the new code"

### 2. Zero-Downtime Worker Replacement

The Etsy deployinator works because Etsy can deploy without taking the site down. For Umi applications:

- **Worker pools**: If you have 10 workers, restart them one at a time. 9/10 capacity is better than 0/10.
- **Request draining**: Let workers finish in-flight work before stopping.
- **Health checks**: New workers prove themselves healthy before old workers stop.

This requires Umi to support:
- Graceful shutdown signaling
- Drain mode (stop accepting new work, finish current work)
- Supervisor-managed rolling restart

### 3. Environment Parity

The deployment failed because QA didn't match production:

> "Production had extra content that included some JavaScript to rewrite part of a page from a third party and it didn't work with the new page structure."

This is outside Umi's scope—it's about deployment pipelines and environment management. But Umi could help with:

- **Configuration isolation**: Make it easy to run with different configs (QA vs prod)
- **Feature flags**: Workers can check flags before using new behavior
- **Shadow mode**: Process real traffic but discard results; compare new vs old behavior

### 4. The Playbook Brittleness

The playbook was rigid: "the playbook has no room for whimsy."

Umi's supervision is the opposite. The supervision tree encodes *policy*, not *procedure*:
- **Policy**: "If this worker crashes, restart it up to 3 times in 60 seconds"
- **Procedure**: "At 11:50pm, DBA runs SQL script, then Sys Ops updates symlinks..."

Policy adapts to runtime conditions. Procedure doesn't.

The deployment army exists because the system doesn't know how to recover from problems. Humans fill in. Umi-based systems should recover automatically from most problems, reducing the human coordination needed during deployment.

### 5. The $100,000 Question

> "It's about $100,000 to run this deployment."

The cost of deployment drives a lot of behavior. If deploys are expensive:
- You batch changes into big releases
- Big releases are riskier
- Risk drives more coordination
- More coordination drives more cost
- Vicious cycle

If deploys are cheap:
- You deploy small changes frequently
- Small changes are less risky
- Less risk means less coordination
- Less coordination means faster deploys
- Virtuous cycle

**For Umi:** The goal should be that upgrading Umi-based applications is cheap. Cheap enough to do multiple times a day. This requires:
- Workers that restart quickly
- Rolling replacement without downtime
- Fast failure detection (catch bad deploys in seconds, not hours)
- Easy rollback (supervisor can restart with old code)

## Questions for Umi

1. **Rolling restart**: Should supervisors support rolling worker replacement? Restart N children at a time?

2. **Drain mode**: Should workers have a standard "draining" state where they finish current work but reject new work?

3. **Code upgrade semantics**: When you update code and restart a supervision tree, what happens? Does the tree restart from the top, or can individual subtrees be replaced?

4. **Version awareness**: Should workers know their own code version? Should supervisors track which version their children are running?

5. **Shadow mode**: Is there value in Umi supporting shadow processing for safe testing of new code?

## The Emotional Core

What struck me most in this chapter isn't the technical details. It's the human cost:

> "I had a deep sense of loss: all that time in the deployment army. All that wasted potential. The wasted humanity!"

Umi is about making systems that run well. But it's also about making systems that don't require armies of humans to keep running. Let-it-crash is humane—it means humans don't have to be the crash recovery mechanism.

The goal isn't just technical excellence. It's freeing people from being used as bots.
