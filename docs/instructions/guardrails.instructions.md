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
- <!-- TODO: Weitere Architektur-Regeln, z.B. Caching-Strategie, Queue-Nutzung, Event-Sourcing-Verbot -->

### Frontend

<!-- TODO: Frontend-Technologie (React, Vue, Alpine, etc.) und Regeln -->

- Never use inline `style` props — utility classes only
- Never use `any` in TypeScript — use `unknown` and narrow it down
- <!-- TODO: Weitere Frontend-Regeln, z.B. "Never use 'let' when 'const' works", "No default exports" -->

### API

<!-- TODO: API-Konventionen, z.B. Datums- und Zahlenformatierung, HTTP-Statuscodes -->

### Documentation

- All documentation files (AGENTS.md, instructions, superpowers specs/plans) are written in **English**
- Code comments are written in **English**
- <!-- TODO: Sprichst du eine andere UI-Sprache? Hier dokumentieren -->

---

## Code Patterns

The agent must always follow these patterns:

### Controller
Controller delegates immediately to Service, returns Resource:

<!-- TODO: ggf. anpassen (z.B. andere Namenskonventionen) -->

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

<!-- TODO: ggf. anpassen an Framework (Vue composables, React hooks, etc.) -->

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

1. `COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail artisan test` — PHPUnit (feature + unit)
2. `COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail composer check` — PHPStan + Pint (format)
3. `COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail npm run test` — <!-- TODO: Frontend-Tests (Vitest o.ä.) -->
4. `COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail npm run check` — ESLint + TypeScript + Prettier
5. `npm run test:e2e` — <!-- TODO: E2E-Tests (Playwright o.ä.), nur auf dem Host -->

<!-- TODO: PHPStan-Level und andere Qualitätsregeln hier dokumentieren -->

---

## Learned Rules

Rules from actual agent mistakes. This section grows with each session.

<!-- Add new rules as bullet points, e.g.: -->
<!-- - Never do X because … (encountered on YYYY-MM-DD) -->
