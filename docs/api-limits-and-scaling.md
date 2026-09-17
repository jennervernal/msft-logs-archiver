# API limits and scaling

Microsoft throttling and capacity are dynamic and workload-, tenant-, resource-, license-, region-, and time-dependent. The profiles in this repository are conservative client safety settings, **not fixed Microsoft API limits**. Microsoft can change service behavior independently of this project.

## Service strategies

- **Graph:** sequential `@odata.nextLink` paging within a stream; page size and time window reduce under pressure. Graph batching is not used and would not eliminate throttling.
- **Purview UAL:** one stable `SessionId` with `ReturnLargeSet`, serialized calls, and an inclusive cmdlet end reduced by one .NET tick to represent `[start,end)`. A window that reaches the configured buffer or 50,000-record session ceiling is bisected; failure is explicit if density remains too high at the minimum window.
- **Azure ARM:** each subscription is an independent source partition. ARM continuation URLs are followed. Remaining-quota headers are treated as early pressure signals when exposed.
- **Defender XDR:** each table is an independent stream. Queries request buffer limit plus one; an overfull result causes bisection before any potentially truncated set is accepted.

## Backpressure behavior

`Invoke-ServiceOperation` retries only HTTP 429, 408, selected 5xx responses, network/timeouts, and narrowly recognized Purview busy/throttle conditions. Authorization, malformed filters/KQL, and other permanent failures are surfaced immediately.

The runtime honors `x-ms-retry-after-ms`, `Retry-After` delta-seconds, and `Retry-After` HTTP-date. Explicit service delay is authoritative even above the configured generated-delay cap. Otherwise it uses capped exponential backoff with full jitter. Supported remaining-quota headers trigger an adaptive reduction. Repeated retryable failures open a service-local circuit breaker for its configured cooldown.

Throttle, transient, dense-result, and low-quota outcomes reduce effective window size and, where applicable, page size and concurrency. Sustained success restores settings gradually. `_state\throttle-state.json` preserves only adaptive state and circuit timing, never credentials or tokens.

## Safe tuning

1. Start with `Small` and collect several representative ranges.
2. Shorten windows first when UAL/Defender are dense or dedupe/queue bounds are approached.
3. Increase page size or concurrency one control at a time only when waits, throttles, low-quota signals, circuits, memory, and disk remain healthy.
4. Keep Purview concurrency at 1. Keep process memory and queue bounds below host capacity.
5. Roll back when cumulative waits, transient counts, circuit events, or elapsed time worsen.

Naive horizontal concurrency can worsen throttling because independent processes do not share adaptive state, quota awareness, user session lifetime, or service-local circuits. It can also race output ownership and generate synchronized retry storms. The exclusive output lock prevents same-root overlap, but it is not a distributed coordinator. Do not fan interactive runs across hosts as a scaling mechanism.

Streaming Graph/ARM records limits memory use, while partition-local dedupe still consumes one key per unique record. UAL/Defender buffers are bounded. Temporary JSONL can be materially larger than gzip output, so disk planning must include both. See [configuration](configuration.md) for knobs and [troubleshooting](troubleshooting.md) for pressure symptoms.
