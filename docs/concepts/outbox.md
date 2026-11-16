# The outbox pattern

## The problem

Your service changes its database and must also publish an event. Do both separately and one will
eventually fail without the other: the order is saved but the event is lost, or the event goes out
and the transaction rolls back. A message you *might* have sent is worse than one you did not send.

## The pattern

Write the event into an `outbox_messages` table **in the same database transaction** as the business
change. Commit once. A separate process, the **outbox processor**, polls that table and forwards the
rows to the platform, then deletes them. The event exists if and only if the business change does.
A crash between commit and forwarding is harmless: the row is still there and is forwarded after the
restart.

```
  your application                      outbox processor                 FlowCatalyst
  ----------------                      ----------------                 ------------
  BEGIN
    save order            ---+
    insert outbox row     ---+--- COMMIT ---> poll, claim a batch -----> POST /api/events/batch
  COMMIT                                      delete rows on success
```

Delivery from the outbox to the platform is at least once. Set a `deduplicationId` on an event when a
repeat must collapse into one.

## What goes in the outbox

The SDKs write three kinds of row: **events**, **dispatch jobs** (a direct webhook with its own
target URL and no subscription) and **audit logs**. Each row has a `message_group`; rows in the same
group are forwarded in order.

| Column | Meaning |
|---|---|
| `id` | Row id. |
| `type` | Event, dispatch job or audit log. |
| `message_group` | Ordering key. Rows in one group are forwarded one at a time, in order. |
| `payload` | The request body to send. |
| `status` | `0` pending, other values claimed or failed. The processor owns this column. |
| `retry_count`, `error_message` | Filled in when forwarding fails. |

The table has the same shape in every SDK. You can create it from your SDK's migration or by running
`fcdev outbox create-table --db-type pg --db-url <url>` (also `mysql` and `mongodb`); both are
idempotent. PostgreSQL, MySQL and MongoDB are supported for the application's outbox.

## The processor

How the processor behaves:

- It claims a batch of pending rows (100 by default) every second when idle, and forwards them to the
  platform's batch endpoints. Successful rows are deleted so the table stays small.
- **Per-group ordering.** With block-on-error on (the default), when one row in a group fails the rest
  of that group's already-claimed rows are released untouched and re-run in order behind it.
- **Retries.** A retryable failure returns the row to pending, up to a cap of 3 attempts, after which the
  row keeps its failure status so it stops looping and an operator can see it.
- **Crash recovery.** Rows stuck in progress for longer than a threshold are reset to pending every
  minute.

You can run it two ways:

| Where | How |
|---|---|
| **Next to your application, against your application's database** | `fcdev outbox` is a standalone poller: `--source-db-url` is your database, `--target-url` is the platform. Use it in development, or deploy it as a sidecar. See [`fcdev outbox`](../reference/fcdev.md#fcdev-outbox). |
| **Inside `fc-server`** | Set `FC_OUTBOX_ENABLED=true` with `FC_OUTBOX_PLATFORM_URL` and a token. The storage backend is `postgres` (the shared pool) or `mongo`, per `FC_OUTBOX_BACKEND`. |

Setting `FC_OUTBOX_ADMIN_PORT` serves an operational API on `127.0.0.1` to list, pause, resume,
unblock and skip groups, which is how you clear a poison row that is blocking its group.

## Writing to the outbox from your code

Every SDK has an outbox manager that writes the row. In TypeScript, using a `pg` pool, the business
write and the event share one transaction:

```typescript
import { Pool } from "pg";
import { CreateEventDto, OutboxManager, PgOutboxDriver } from "@flowcatalyst/sdk";

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const outbox = new OutboxManager(new PgOutboxDriver(pool), "clt_your_client_id");

const tx = await pool.connect();
try {
  await tx.query("BEGIN");
  await tx.query("UPDATE orders SET status = 'shipped' WHERE id = $1", [orderId]);
  await outbox.createEvent(
    CreateEventDto.create("orders:fulfillment:order:shipped", { orderId })
      .withSource("order-service")
      .withMessageGroup(orderId),
    tx, // the row joins this transaction
  );
  await tx.query("COMMIT");
} catch (err) {
  await tx.query("ROLLBACK");
  throw err;
} finally {
  tx.release();
}
```

Event type codes passed to the SDK must be fully qualified, `application:subdomain:aggregate:event`;
a bare code is rejected before anything is written. See [TypeScript](../sdks/typescript.md#the-outbox),
[Laravel](../sdks/laravel.md#the-outbox) and [Java](../sdks/java.md#the-outbox) for each SDK.
