# UniPay — Coding Standards

> **AI Instruction**: Every line of code written for UniPay must follow
> these standards. These are not suggestions. Apply them without being asked.

---

## TypeScript

- Strict mode enabled in all `tsconfig.json` files — `"strict": true`
- No `any` type anywhere. Use `unknown` and narrow it.
- No non-null assertions (`!`) unless the value is provably non-null
- All function parameters and return types must be explicitly typed
- Use `type` for object shapes, `interface` only for things that get extended
- Prefer `const` over `let`. Never use `var`.
- Use optional chaining (`?.`) and nullish coalescing (`??`) over ternaries

```typescript
// WRONG
const name = user.profile.name;

// RIGHT
const name = user.profile?.name ?? 'Unknown';
```

---

## Naming Conventions

### Files
- SvelteKit routes: SvelteKit convention (`+page.svelte`, `+layout.ts`)
- Svelte components: `PascalCase.svelte` (e.g. `AttendanceCodeInput.svelte`)
- Rune state files: `camelCase.svelte.ts` (e.g. `auth.svelte.ts`)
- Worker modules: `domain.role.ts` (e.g. `attendance.service.ts`)
- Database files: `snake_case.sql` (e.g. `create_sheet.sql`)
- Utility files: `camelCase.ts` (e.g. `currency.ts`)

### Variables and Functions
- Variables: `camelCase`
- Functions: `camelCase` verbs (`createSheet`, `markAttendance`, `formatLKR`)
- Constants: `SCREAMING_SNAKE_CASE` (`MAX_DURATION_SECONDS`, `COOKIE_NAME`)
- Types and interfaces: `PascalCase` (`AttendanceSheet`, `UserRole`)
- Zod schemas: `camelCase` with `Schema` suffix (`createSheetSchema`)
- Database columns: `snake_case` (enforced by PostgreSQL)

### Database
- Tables: `snake_case` plural (`attendance_sheets`, `user_sessions`)
- Columns: `snake_case` (`university_index`, `created_at`)
- Functions: `snake_case` verbs (`create_sheet`, `mark_attendance`)
- Enums: `snake_case` type name, `snake_case` values (`user_role`, `undergraduate`)
- Indexes: `idx_tablename_column` (`idx_users_university_index`)

---

## Component Structure (Svelte 5)

Every component follows this order:

```svelte
<script lang="ts">
  // 1. Imports — external first, internal second
  import { onMount } from 'svelte';
  import type { AttendanceSheet } from '$shared/types/attendance';
  import { createSheet } from '$lib/api/attendance';

  // 2. Props (Runes)
  let { sheetId, onClose }: { sheetId: string; onClose: () => void } = $props();

  // 3. State (Runes)
  let loading = $state(false);
  let error = $state<string | null>(null);

  // 4. Derived values (Runes)
  let isValid = $derived(sheetId.length === 5);

  // 5. Effects
  $effect(() => {
    // reactive side effects here
  });

  // 6. Functions
  async function handleSubmit() {
    // ...
  }
</script>

<!-- Template -->
<div>
  <!-- content -->
</div>
```

---

## API Client Usage (Frontend)

Never call `fetch()` directly in a component or state file.
Always use the typed wrappers in `$lib/api/`.

```typescript
// WRONG — never do this in a component
const res = await fetch('/api/v1/attendance/sheets', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(data)
});

// RIGHT — always do this
import { createSheet } from '$lib/api/attendance';
const sheet = await createSheet(data);
```

---

## Worker Controller Structure (Hono)

Every controller follows this pattern:

```typescript
import { Hono } from 'hono';
import { zValidator } from '@hono/zod-validator';
import { authMiddleware } from '../../middleware/auth.middleware';
import { createSheetSchema } from '@unipay/shared/validation/attendance.schema';
import { AttendanceService } from './attendance.service';

const attendance = new Hono();

attendance.post(
  '/sheets',
  authMiddleware,          // 1. Verify JWT cookie
  zValidator('json', createSheetSchema),  // 2. Validate body
  async (c) => {
    const body = c.req.valid('json');
    const user = c.get('user');           // 3. Get user from middleware context

    const sheet = await AttendanceService.createSheet({
      createdBy: user.sub,
      ...body
    });

    return c.json({ success: true, data: sheet }, 201);
  }
);

export { attendance };
```

---

## Error Handling

### Worker
All errors bubble to `error.middleware.ts`. Controllers never catch and
swallow errors — they let them propagate.

```typescript
// WRONG
try {
  const sheet = await AttendanceService.createSheet(data);
  return c.json({ sheet });
} catch (e) {
  return c.json({ error: 'Something went wrong' }, 500);
}

// RIGHT — let it propagate, error middleware handles it
const sheet = await AttendanceService.createSheet(data);
return c.json({ success: true, data: sheet }, 201);
```

### Frontend
Every API call must handle three states: loading, success, error.
No silent failures.

```svelte
<script lang="ts">
  let loading = $state(false);
  let error = $state<string | null>(null);
  let result = $state<Sheet | null>(null);

  async function submit() {
    loading = true;
    error = null;
    try {
      result = await createSheet(formData);
    } catch (e) {
      error = e instanceof Error ? e.message : 'Something went wrong';
    } finally {
      loading = false;
    }
  }
</script>

{#if loading}<Spinner />{/if}
{#if error}<ErrorMessage {error} />{/if}
{#if result}<SuccessView {result} />{/if}
```

---

## Money Handling

All monetary values are `BIGINT` cents in the database and `number` (integer)
in TypeScript. Never use floating point for money.

```typescript
// WRONG
const price = 150.50;  // floating point
const price = '150.50';  // string

// RIGHT
const priceCents = 15050;  // integer cents

// Format for display using the utility function
import { formatLKR } from '$lib/utils/currency';
formatLKR(15050)  // → "LKR 150.50"
```

```typescript
// currency.ts
export function formatLKR(cents: number): string {
  return `LKR ${(cents / 100).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')}`;
}

export function lkrToCents(lkr: number): number {
  return Math.round(lkr * 100);
}
```

---

## Duration Handling (Attendance)

Duration is always stored as total seconds (integer) in the database.
The UI shows minutes and seconds separately. Convert at the boundary.

```typescript
// duration.ts
export function secondsToLabel(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  if (m === 0) return `${s}s`;
  if (s === 0) return `${m}m`;
  return `${m}m ${s}s`;
}
// secondsToLabel(150) → "2m 30s"
// secondsToLabel(180) → "3m"
// secondsToLabel(45)  → "45s"

export function toSeconds(minutes: number, seconds: number): number {
  return (minutes * 60) + seconds;
}
```

---

## Import Aliases

These path aliases are configured in `tsconfig.json` and `svelte.config.js`:

| Alias | Resolves to | Used in |
|---|---|---|
| `$lib` | `frontend/src/lib/` | Frontend only |
| `$shared` | `shared/src/` | Frontend + Worker |
| `@unipay/shared` | `shared/src/` | Worker (npm workspace) |

```typescript
// Frontend example
import { formatLKR } from '$lib/utils/currency';
import type { AttendanceSheet } from '$shared/types/attendance';

// Worker example
import { createSheetSchema } from '@unipay/shared/validation/attendance.schema';
```

---

## SQL Style

```sql
-- Keywords uppercase
SELECT id, full_name, university_index
FROM users
WHERE role = 'undergraduate'
  AND status = 'active'
ORDER BY created_at DESC;

-- Functions use snake_case
SELECT create_sheet($1, $2, $3, $4, $5);

-- Always use parameterised queries — never string interpolation
-- WRONG:
`SELECT * FROM users WHERE email = '${email}'`

-- RIGHT:
db.query('SELECT * FROM users WHERE email = $1', [email])
```

---

## Git Commit Convention

```
type(scope): short description

Types: feat, fix, schema, config, docs, refactor, test
Scopes: auth, payment, attendance, merchant, analytics, admin, db, worker, frontend, shared

Examples:
feat(attendance): add manual_add_attendance function
fix(payment): prevent double charge on network timeout
schema(db): add is_flagged index on attendance_records
config(worker): add expireSheets cron trigger
```
