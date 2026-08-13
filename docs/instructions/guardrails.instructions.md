# Guardrails & Anti-Patterns

Rules the agent must never break.
This file grows with every actual problem encountered.

---

## Hard Constraints

The following is **never** allowed — no exceptions:

### Security

- Never hardcode secrets, API keys, passwords, or tokens in code
- Never use `eval()`, `exec()`, `shell_exec()`, or similar functions
- Never use `DB::raw()` with unvalidated user input
- Never use mass assignment without `$fillable` — `$guarded = []` is forbidden

### Architecture

<!-- TODO: Project-specific architectural constraints -->

- Never introduce a Repository pattern — Services use Eloquent directly
- Never put business logic in Controllers — always Form Request → Service → Resource
- Never use `Gate::` or `$this->authorize()` inline — always Policies
- Never use `response()->json()` or return raw models — always API Resources
- <!-- TODO: Further architecture rules, e.g. caching strategy, queue usage, event-sourcing ban -->

### Frontend

<!-- TODO: Frontend technology (React, Vue, Alpine, etc.) and rules -->

- Never use inline `style` props — utility classes only
- Never use `any` in TypeScript — use `unknown` and narrow it down
- <!-- TODO: Further frontend rules, e.g. "Never use 'let' when 'const' works", "No default exports" -->

### API

<!-- TODO: API conventions, e.g. date and number formatting, HTTP status codes -->

### Documentation

- All documentation files (AGENTS.md, instructions) are written in **English**
- Code comments are written in **English**
- <!-- TODO: Do you use a different UI language? Document it here -->

---

## Code Patterns

The agent must always follow these patterns:

### Controller
Controller delegates immediately to Service, returns Resource:

<!-- TODO: adjust if needed (e.g. other naming conventions) -->

```php
public function store(StoreFooRequest $request): FooResource
{
    return new FooResource($this->fooService->create($request->validated()));
}
```

### Service
Services contain all business logic, use Eloquent directly:

```php
public function create(array $data): Model
{
    return DB::transaction(fn () => Model::create($data));
}
```

### API Client (Frontend)
All API calls through dedicated service modules:

<!-- TODO: adjust to the framework if needed (Vue composables, React hooks, etc.) -->

```ts
// src/services/fooService.ts
export async function getFoos(): Promise<Foo[]> {
  const { data } = await apiClient.get('/api/v1/foos');
  return data.data;
}
```

### TypeScript
Props as `interface`, not `type`:

```tsx
interface FooProps {
  items: Foo[];
  onAction: (id: number) => void;
}

export function Foo({ items, onAction }: FooProps) { /* ... */ }
```

---

## Domain Invariants

<!-- TODO: Non-negotiable business rules here. These are the rules that, if violated, cause data corruption.
Examples:
- "Transaction XOR: exactly one of account_id or savings_pot_id set — never both, never neither"
- "At least one admin: the last admin must not be deleted"
- "Amount always positive — type determines sign"
-->

---

## Validation Flow

Run in this order before claiming completion:

1. `COMPOSE_PROJECT_NAME=<PROJECT_NAME> ./vendor/bin/sail artisan test` — PHPUnit (feature + unit)
2. `COMPOSE_PROJECT_NAME=<PROJECT_NAME> ./vendor/bin/sail composer check` — PHPStan + Pint (format)
3. `COMPOSE_PROJECT_NAME=<PROJECT_NAME> ./vendor/bin/sail npm run test` — <!-- TODO: Frontend tests (Vitest or similar) -->
4. `COMPOSE_PROJECT_NAME=<PROJECT_NAME> ./vendor/bin/sail npm run check` — ESLint + TypeScript + Prettier
5. `npm run test:e2e` — <!-- TODO: E2E tests (Playwright or similar), host only -->

<!-- TODO: Document the PHPStan level and other quality rules here -->

---

## Learned Rules

Rules from actual agent mistakes. This section grows with each session.

<!-- Add new rules as bullet points, e.g.: -->
<!-- - Never do X because … (encountered on YYYY-MM-DD) -->
