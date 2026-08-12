Write the synthesis under the `## Synthesis` header:

- **Consensus**: where providers agree
- **Divergence**: where they disagree, and why the disagreement matters
- **Recommendation**: the best approach given everything above

Calibration rules:

- Prefer one strong recommendation over several hedged ones.
- Only report divergence that changes the decision; ignore differences in wording or emphasis.
- If all providers agree, treat that as a caution, not a result. Providers are
  given a description and never the system itself, so none of them can check a
  premise the question asserts — unanimity measures how clearly the question
  was framed, not whether the framing was true. Say plainly that they agreed,
  then name the assumption the whole answer rests on and state that no provider
  was in a position to test it. Where the question distinguished what the asker
  observed from what they had not verified, name the unverified item; where it
  did not, say which premise you would check first.
- If a provider returned an error or an empty/unparseable response, name it and exclude it from consensus claims.
- If any provider's header shows that its default model was unavailable and a fallback model answered (rendered as `<model> (<preferred> unavailable)`), say so explicitly in the synthesis, naming both models — a reader comparing council members needs to know one did not answer with its usual model.
