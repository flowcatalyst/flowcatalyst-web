# Laravel SDK

`flowcatalyst/laravel-sdk` lets a Laravel application use FlowCatalyst as its **identity provider and
authorization layer** and talk to the event-driven control plane, in idiomatic Laravel.

- **Sign in with FlowCatalyst (OIDC).** Stock `->middleware('auth')` drives the login flow, with no
  scaffolding.
- **Authorization like Spatie.** `$user->can(...)`, `@can`, `hasRole()` and policies, backed by
  FlowCatalyst roles and permissions. Run it stateless (no users table) or sync into a local `users`
  table with `spatie/laravel-permission`.
- **Declare and sync** roles, permissions, event types, subscriptions and more as PHP attributes.
- **Outbox** for events and dispatch jobs, **control-plane client**, and **webhook validation**.

Requirements: PHP 8.1 or later, Laravel 10, 11, 12 or 13. The outbox needs MySQL 8.0, PostgreSQL 12 or
MongoDB 4.4.

## Install

```sh
composer require flowcatalyst/laravel-sdk
php artisan vendor:publish --tag=flowcatalyst-config
```

Add the connection settings to `.env`. For local development, run
[`fcdev init`](../reference/fcdev.md#fcdev-init) to create an application and have it write the base
URL, client id and secret for you.

```env
FLOWCATALYST_BASE_URL=http://localhost:8080
FLOWCATALYST_CLIENT_ID=your_client_id
FLOWCATALYST_CLIENT_SECRET=your_client_secret
FLOWCATALYST_OUTBOX_DRIVER=database
FLOWCATALYST_SIGNING_SECRET=your_signing_secret   # for webhook validation
```

## Sign in with FlowCatalyst

A fresh Laravel app needs only environment variables:

```env
FLOWCATALYST_BASE_URL=https://platform.example.com
FLOWCATALYST_OIDC_ENABLED=true
FLOWCATALYST_NATIVE_LOGIN=true
FLOWCATALYST_OIDC_CLIENT_ID=your_oauth_client_id
FLOWCATALYST_OIDC_CLIENT_SECRET=your_oauth_client_secret   # omit for a PKCE-only public client
FLOWCATALYST_OIDC_SCOPE="openid profile email offline_access"
```

```php
// routes/web.php
Route::middleware('auth')->group(function () {
    Route::get('/dashboard', DashboardController::class);
});
```

With the native-login bridge on (`FLOWCATALYST_NATIVE_LOGIN=true`, opt-in so the SDK never changes an
existing app's authentication), a guest who hits an `auth` route is redirected into the FlowCatalyst
login flow with no `login` route of your own. The SDK registers `/flowcatalyst/login`, `/callback`,
`/logout` and `/refresh`. On the FlowCatalyst OAuth client, use the `authorization_code` grant and the
redirect URI `https://your-app.example.com/flowcatalyst/callback`, which must match exactly,
including `localhost` versus `127.0.0.1`.

Check permissions the Laravel way. Permissions are four-part
`application:context:aggregate:action` strings and role names are prefixed with the application code:

```php
$user->hasPermissionTo('orders:admin:order:cancel');
$user->hasRole('orders:admin');
$user->can('orders:admin:order:cancel');   // Gate, @can and policies route here
```

## Declaring and syncing definitions

Your repository is the source of truth. Define permissions and roles as classes, attribute them, and
push them to the platform. There is no standalone "create permission" endpoint, so permissions reach
the platform through the roles that grant them.

```php
// app/FlowCatalyst/Permissions/ViewPosts.php
use FlowCatalyst\Attributes\AsPermission;

#[AsPermission(context: 'posts', aggregate: 'post', action: 'view', description: 'View posts')]
class ViewPosts {}
```

```php
// app/FlowCatalyst/Roles/EditorRole.php
use FlowCatalyst\Attributes\AsRole;

#[AsRole(name: 'editor', displayName: 'Editor', permissions: [ViewPosts::class, EditPosts::class])]
class EditorRole {}
```

```php
// app/UseCases/Comments/CommentCreated.php
use FlowCatalyst\Attributes\AsEventType;

#[AsEventType(subdomain: 'comments', aggregate: 'comment', event: 'created', name: 'Comment Created', clientScoped: true)]
final class CommentCreated extends BaseDomainEvent { /* ... */ }
```

The application segment comes from `FLOWCATALYST_APP_CODE`. Sync with a service account that has
write access to the application:

```env
FLOWCATALYST_CLIENT_ID=svc_...        # client_credentials credentials
FLOWCATALYST_CLIENT_SECRET=...
FLOWCATALYST_APP_CODE=blog            # the application that owns these definitions
```

```sh
php artisan flowcatalyst:scan            # find the attributed classes, cache them
php artisan flowcatalyst:sync --dry-run  # preview
php artisan flowcatalyst:sync            # push to the platform
```

The same mechanism covers `#[AsSubscription]`, `#[AsConnection]`, `#[AsDispatchPool]`, `#[AsProcess]`
and `#[AsScheduledJob]`. If `spatie/laravel-permission` is installed, sync also seeds the local Spatie
tables. List the directories that hold attributed classes in `flowcatalyst.definitions.paths`.

## The outbox

Publish and run the migration, then write events inside your own transactions:

```sh
php artisan vendor:publish --tag=flowcatalyst-migrations
php artisan migrate
```

```php
use FlowCatalyst\Facades\Outbox;
use FlowCatalyst\Outbox\DTOs\CreateEventDto;

$eventId = Outbox::createEvent(
    CreateEventDto::create(
        type: 'orders:fulfillment:order:created',
        data: ['orderId' => 'ORD-123', 'total' => 99.99],
    )->withCorrelationId('corr-abc-123')
     ->withSource('order-service')
     ->withMessageGroup('orders')      // per-group ordering
);
```

The SDK only **writes rows**. A poller forwards them: run `fcdev outbox` against your application's
database in development, or the outbox processor in production
([The outbox pattern](../concepts/outbox.md)). Two environment variables link emitted events to
your application and tenant: `FLOWCATALYST_APP_CODE` and `FLOWCATALYST_CLIENT_CODE`. The same facade
creates direct dispatch jobs (`Outbox::createDispatchJob(...)`).

## Webhook validation

Verify HMAC-signed deliveries with the route middleware or by hand:

```php
// routes/api.php
Route::post('/webhooks/flowcatalyst', [WebhookController::class, 'handle'])
    ->middleware('flowcatalyst.webhook');
```

```php
use FlowCatalyst\Webhook\WebhookValidator;
use FlowCatalyst\Exceptions\WebhookValidationException;

try {
    WebhookValidator::fromConfig()->validateRequest($request);
} catch (WebhookValidationException $e) {
    return response()->json(['error' => 'Invalid signature'], 401);
}
```

It reads the secret from `FLOWCATALYST_SIGNING_SECRET`. See
[Messaging and delivery](../concepts/messaging-and-delivery.md#signatures) for what is signed.

## Also in the package

A typed control-plane client (`FlowCatalyst::eventTypes()`, `subscriptions()`, `dispatchPools()`,
`roles()`, `applications()` and more), portal-identity helpers for customer portals, an MCP server
for AI assistants, and Artisan commands `flowcatalyst:scan`, `flowcatalyst:sync`,
`flowcatalyst:session-table` and `flowcatalyst:verify-signature`. The package README in the
repository (`clients/laravel-sdk/README.md`) is the complete reference.
