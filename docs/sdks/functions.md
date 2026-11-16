# Function SDKs

These are the **guest** SDKs: the libraries you compile a [function](../concepts/functions.md) against.
They are not clients for calling the platform. A function declares its endpoints, subscriptions,
schedules and capabilities in code, and the platform reads those declarations from the built
artifact.

| Language | Package | Artifact | Source |
|---|---|---|---|
| Go | `github.com/flowcatalyst/flowcatalyst-go/clients/fn-go` (package `fn`) | WebAssembly | `clients/fn-go` |
| Rust | crate `flowcatalyst-fn` | WebAssembly | `clients/fn-rust` |
| TypeScript | `@flowcatalyst/fn` | one bundled JavaScript file | `clients/fn-ts` |

Go and Rust compile to WebAssembly. TypeScript does not: the artifact is a single bundled script
that runs on the runner's shared JavaScript engine (QuickJS), which keeps a TypeScript function's cost
to its own instances.

## Get started

Scaffold a project with `fcdev`, then build and run it locally. See [Functions](../concepts/functions.md)
for the full loop (`build`, `run`, `deploy`, `promote`).

```sh
fcdev fn init --lang go --app billing --sdk-path /path/to/flowcatalyst/clients invoice-pdf
cd invoice-pdf && go mod tidy
fcdev fn build
fcdev fn run function.wasm --config GREETING=Hi
curl -H "Authorization: Bearer dev" localhost:8099/fn/local.fn/hello/Aroha
```

`--lang` is `go`, `rust` or `ts`. `--app` is the owning application's code, and the directory name is
the function name (lower-case letters, digits and hyphens), so the address here is
`billing.invoice-pdf`. `--sdk-path` points at the `clients/` directory of a repository checkout so the
scaffold depends on the SDK source there. Without it the scaffold names the published package
versions, which only helps once those packages are published to their registries.

## Go

Handlers are plain `net/http` handlers. Go 1.24 or later.

```go
package main

import (
	"net/http"

	fn "github.com/flowcatalyst/flowcatalyst-go/clients/fn-go"
)

var greeting = fn.Config("GREETING")

func init() {
	fn.Open("GET /healthz", health)
	fn.Platform("GET /hello/{name}", hello)
}

func main() {}

func health(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) }

func hello(w http.ResponseWriter, r *http.Request) {
	g, found, _ := greeting.Get(r.Context())
	if !found {
		g = "Hello"
	}
	w.Write([]byte(g + ", " + r.PathValue("name")))
}
```

The declaration API is `Webhook`, `Platform`, `Open`, `Subscribe`, `Schedule`, `Config`, `Secret`,
`DB`, `HTTPAllow` and `Emits`. Delivery answers use `fn.Retry(w, d)` and `fn.Reject(w, reason)`. The
SDK has zero third-party dependencies and is tested on the host with a fake host, with no WebAssembly
runtime required (`go test ./...` in `clients/fn-go`).

## TypeScript

```typescript
import { fn } from "@flowcatalyst/fn";

const greeting = fn.config("GREETING");

fn.open("GET /healthz", () => fn.json(200, { status: "ok" }));

fn.platform("GET /hello/{name}", (req) =>
  fn.json(200, { message: `${greeting.get() ?? "Hello"}, ${req.params.name}` }),
);

fn.webhook("POST /events/greeting", async (req) => {
  const ev = req.json() as { id?: string };
  await fn.emit({
    type: "hello:greeting:greeting:sent",
    dedupId: `greeting-sent-${ev.id}`,
    data: { ok: true },
  });
  return fn.status(202);
});

fn.emits("hello:greeting:greeting:sent");
```

The package has zero runtime dependencies and builds with strict TypeScript. QuickJS has no
`Headers` or `URLSearchParams`, so the SDK provides its own.

## Rust

Crate `flowcatalyst-fn`, edition 2021, depending only on `serde` and `serde_json`, targeting
`wasm32-unknown-unknown`.

```rust
use flowcatalyst_fn::{App, Context, Error, Request, Response};

flowcatalyst_fn::export!(|app: &mut App| {
    app.webhook("POST /events/x", handler)
       .platform("GET /hello/{name}", hello)
       .open("GET /healthz", health)
       .subscribe("t:y:z:w", "/events/x")
       .config("GREETING")
       .db("main")
       .http_allow("api.x.com")
       .emits("a:b:c:d");
});
```

All three SDKs declare the same things with the same meaning, and evaluate a permission the same way
(`Principal.HasPermission` with the platform's wildcard rules).
