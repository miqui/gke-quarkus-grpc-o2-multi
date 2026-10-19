# Tracing Claude API calls (proposed, not applied)

How to trace calls to the Claude API with OpenTelemetry, if `job-manager-api` (or anything else in
this repo) starts calling Claude. Nothing here is implemented: the service has no `anthropic-java`
dependency and makes no Claude calls today. This guide fits the Claude SDK's tracing into the
pipeline that already exists (`TRACING.md`): Quarkus OpenTelemetry -> `otel-collector:4318` ->
OpenObserve.

Claude's OpenTelemetry export is in beta. Span names, attributes and options can change, so pin
the SDK version. Current docs: <https://platform.claude.com/docs/en/manage-claude/opentelemetry.md>.

## Two sources of spans

| | SDK tracing | API tracing |
| --- | --- | --- |
| Emitted by | `anthropic-java`, inside the pod | Anthropic's API, server-side |
| Sent through | the app's own exporter, so the existing collector | a *destination* (public OTLP/HTTPS endpoint) that an org admin registers |
| Setup | code + config | Admin API or Console, no code |
| Shows | one `anthropic.messages.create` span (`CLIENT`) per call, with token usage | the `SERVER` span under it, one `anthropic.model_request` per model call, server-tool spans |
| `service.name` | `job-manager-api` | `claude-platform` |

**Recommendation for this repo: SDK tracing only.** It goes through the collector already in
place and needs no public endpoint. API tracing only adds the breakdown inside a request, which
matters for server tools or agents, not for a single classification or summary call.

## SDK tracing

### 1. Dependency

```xml
<dependency>
    <groupId>com.anthropic</groupId>
    <artifactId>anthropic-java</artifactId>
    <version>2.34.0</version> <!-- use the latest release; tracing needs a recent SDK -->
</dependency>
```

No OpenTelemetry SDK or exporter to add: `quarkus-opentelemetry` already provides both. The Claude
SDK needs `opentelemetry-api` 1.57.0 or later. Quarkus 3.40.1 resolves 1.62.0 here (check with
`./mvnw dependency:tree -Dincludes=io.opentelemetry:opentelemetry-api`).

### 2. Build the client on Quarkus's tracer provider

Quarkus creates its OpenTelemetry SDK as a CDI bean and does not register it as the global
instance. So pass its tracer provider to the client explicitly. If you don't, the Claude SDK finds
no global provider and emits nothing.

```java
@ApplicationScoped
public class ClaudeClientProducer {

    @Produces
    @Singleton
    AnthropicClient claude(OpenTelemetry openTelemetry) {
        // fromEnv() reads ANTHROPIC_API_KEY and the ANTHROPIC_OPEN_TELEMETRY_* variables;
        // start from OpenTelemetryOptions.fromEnv() so the code below keeps them.
        var envOptions = OpenTelemetryOptions.fromEnv();
        return AnthropicOkHttpClient.builder()
                .fromEnv()
                .openTelemetry(envOptions.toBuilder()
                        .tracerProvider(openTelemetry.getTracerProvider())
                        .build())
                .build();
    }

    void close(@Disposes AnthropicClient client) {
        client.close();
    }
}
```

Imports come from `com.anthropic.client`, `com.anthropic.client.okhttp` and
`io.opentelemetry.api`. The package of `OpenTelemetryOptions` isn't documented in the guide this
is based on, so let the compiler find it. Build the client once and reuse it.

### 3. Call it inside the RPC's span

Inside a `@RunOnVirtualThread` handler the gRPC server span is already current, so a plain
`client.messages().create(params)` produces:

```
job.v1.JobService/<Method>          SERVER  (quarkus-opentelemetry)
  anthropic.messages.create         CLIENT  (anthropic-java, model, token usage)
    anthropic.messages.create       SERVER  (Anthropic API - only with API tracing)
```

To link several calls as one conversation, set a conversation ID per call through
`RequestOptions` / `OpenTelemetryRequestOptions.conversationId(...)`. It is exported in every
content mode, so use an opaque ID (such as the job ID), never personal data.

### 4. Make the existing sampler keep Claude spans

`config/TracingConfig.java` changes what you'll see in two ways:

- **Root `CLIENT` spans are dropped.** A Claude call made outside an RPC (from a scheduler like
  the lease reaper) would have its span dropped, exactly like the reaper's JDBC spans. Either wrap
  background calls in an `INTERNAL` span of your own, or exempt them in the sampler:
  `if (root && spanKind == SpanKind.CLIENT && !name.startsWith("anthropic.")) drop`.
- **Only 10% of RPCs are sampled** (`TRACES_SAMPLING_PROBABILITY`). Claude spans follow their
  parent, so 90% of calls leave no span. For cost tracking, don't sum token counts from spans at
  this ratio. Use the Usage API, or record `response.usage()` as a Micrometer counter, which
  `PROMETHEUS.md`'s pipeline already exports.

### 5. Configuration

Add these to `k8s/configmap.yaml` / the Deployment:

| Variable | Value | Why |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | from a Secret | Add it to GCP Secret Manager through `gke-secrets-seed.sh` and sync it with an `ExternalSecret`, like the OpenObserve credentials. Never put it in the ConfigMap |
| `ANTHROPIC_OPEN_TELEMETRY_TRACES_CONTENT_MODE` | leave unset (`metadata_only`) | `content` would put prompts and responses into OpenObserve, which has a 5Gi PVC and 3-day retention, and no access controls beyond the root login |
| `ANTHROPIC_OPEN_TELEMETRY` | `false` only to turn the spans off | e.g. if a vendor agent starts instrumenting the SDK as well (each call would appear twice) |

### 6. Network policy: allow egress to the API

The `job-manager-api` NetworkPolicy (`k8s/networkpolicies.yaml`) allows egress only to Hazelcast,
Cloud SQL and the collector, so a Claude call would time out. Add a rule for TCP 443. A plain
NetworkPolicy can't select by hostname, so the choices are:

- `ipBlock: 0.0.0.0/0` on port 443 (simple, but it opens all HTTPS egress), or
- GKE's `FQDNNetworkPolicy` for `api.anthropic.com`. This needs GKE Dataplane V2 and the FQDN
  network policy feature on the cluster, which `gke-bootstrap.sh` would have to enable.

### 7. Verify

1. Locally, against the compose collector with its `debug` exporter, at
   `TRACES_SAMPLING_PROBABILITY=1.0`. Expect an `anthropic.messages.create` span of kind `CLIENT`
   under the RPC span, with `gen_ai.provider.name=anthropic`, `gen_ai.usage.input_tokens` /
   `output_tokens`, and `anthropic.request.id`.
2. On GKE: query OpenObserve for `operation_name = 'anthropic.messages.create'` with the query in
   `TRACING.md` -> Verification.
3. Check that the outgoing request carries a `traceparent` header (it shows up as the API span's
   parent once API tracing is on). The SDK writes it with the application's propagator. Quarkus
   configures `tracecontext,baggage` on its own OpenTelemetry instance, not globally, so this is
   the step most likely to need adjusting. It matters only for API tracing.

### Troubleshooting

| Problem | Check |
| --- | --- |
| No Claude spans | The client was built with Quarkus's tracer provider (step 2); the RPC was sampled (10%); the call wasn't a root `CLIENT` span (step 4); `ANTHROPIC_OPEN_TELEMETRY` isn't `false` |
| No spans at all, even local | Another dependency pins `opentelemetry-api` below 1.57.0 |
| Call times out on GKE | Egress rule (step 6) |
| Span of a streamed call never ends | Read the stream to the end or close it. Use `messages().createStreaming()` so the span gets the response |

## API tracing (optional)

Use it only if Claude calls start using server tools (web search, code execution) or Managed
Agents, where the interesting steps happen server-side.

What it would take here:

- **A public HTTPS endpoint on port 443 with a hostname.** The collector is a ClusterIP service on
  4318. You'd have to expose its OTLP/HTTP receiver through the Gateway (e.g. `otlp.miqui.dev`)
  with authentication on the receiver (the collector's `bearertokenauth` extension). That's a new
  public write endpoint into the observability stack. The alternative is a hosted backend
  (Grafana Cloud, Honeycomb, ...) as a second destination for these spans only.
- **An org admin** to add the destination, with `ant beta:organization:telemetry-destinations
  create` or Console -> Settings -> OpenTelemetry. This sends the organization's Claude traces to a
  third-party endpoint, so it is a decision for whoever owns the Anthropic organization.
- **The short-lived cluster.** When the cluster is torn down, deliveries fail. After 24 hours of
  failures the API disables the destination (`sustained_failure`). Re-enable it after each
  `gke-bootstrap.sh`, or use a hosted backend that doesn't come and go with the cluster.
- **Sampling.** The API emits nothing for a request whose `traceparent` has the sampled flag off.
  At a 10% ratio, API spans exist only for the sampled 10%.

In the backend, API spans have `service.name = claude-platform`. A request with both sources has two
spans named `anthropic.messages.create`: the SDK's (`CLIENT`) and the API's (`SERVER`, its child).
When summing tokens, use one source per request: the API spans if both exist.
