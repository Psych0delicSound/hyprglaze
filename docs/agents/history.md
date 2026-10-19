# History / do not reintroduce

Read before touching anything that looks removed or forbidden.

- The upstream `ai_buddy` effect (Claude Haiku on AWS Bedrock, shelling out to
  the `aws` CLI) was deliberately removed at the user's request — do not
  reintroduce it, or any network-/credential-dependent code path.
- Remaining subprocess use: `popen("pactl get-default-sink …")` for audio sink
  detection only.
