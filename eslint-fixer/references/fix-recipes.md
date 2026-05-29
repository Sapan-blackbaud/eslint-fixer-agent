# ESLint Fix Recipes

Per-rule playbooks. Each recipe lists: **autofixable?**, **risk**, **pattern**, **anti-pattern (don't do this)**, and **verification hint**.

> Recipes are biased toward the rules that dominate the Allocations Frontend lint report. Add new ones as you encounter them.

---

## TypeScript: `no-unsafe-*` family

Rules: `no-unsafe-assignment`, `no-unsafe-member-access`, `no-unsafe-call`, `no-unsafe-argument`, `no-unsafe-return`, `no-unsafe-enum-comparison`.

**Autofixable?** No.
**Risk:** High (type changes can cascade).

**Root cause:** A value typed `any` (often from an untyped API response, JSON.parse, or third-party lib) is being used as if it were typed.

**Pattern:**
1. Walk up to the source of the `any`. Usually it's an HTTP call (`HttpClient.get()` without a generic), a `JSON.parse`, or a `Record<string, any>`.
2. Add the missing type parameter at the source:
   ```ts
   // before
   this.http.get(url).subscribe(r => this.name = r.name);
   // after
   interface UserResponse { name: string; }
   this.http.get<UserResponse>(url).subscribe(r => this.name = r.name);
   ```
3. If the response shape is unknown, search the OpenAPI / swagger gen output (`src/app/core/api/**`) for an existing interface first.

**Anti-pattern (banned):**
- `(r as any).name` — re-introduces unsafe access.
- `(r as unknown as UserResponse)` — masks the real fix.
- Casting to `unknown` and then narrowing only when there's no type info available at all.

**Verification:** scoped re-lint should drop all `no-unsafe-*` messages for the touched lines; `tsc --noEmit` must pass.

---

## TypeScript: `no-explicit-any`

**Autofixable?** No.
**Risk:** Medium.

**Pattern:**
1. Infer the type from usage. Where is the value read? What properties are accessed? Build a minimal interface.
2. For function parameters, look at all call sites for the expected shape.
3. For generics, use `<T>` rather than `any`.
4. For values that are genuinely unknown at type-check time (e.g. `catch (e)`), use `unknown` and narrow with `instanceof` / type guards.

**Anti-pattern:** replacing `any` with `unknown` everywhere without narrowing — moves the problem to use sites.

**Verification:** confirm the new type compiles and the original `: any` token is gone at the reported column.

---

## TypeScript: `no-namespace`

**Autofixable?** No.
**Risk:** Low (mechanical).

**Pattern:**
```ts
// before
namespace MyFeature {
  export interface Foo { ... }
  export const bar = 1;
}
// after
export interface Foo { ... }
export const bar = 1;
// callers: import { Foo, bar } from './my-feature';
```

If the namespace is large, prefer keeping it as a single module rather than splitting files. Use `// eslint-disable-next-line` only if the namespace wraps ambient declarations for a third-party lib — and then **ask the user first**.

**Verification:** the `namespace` keyword at the reported line should be gone; all callers compile.

---

## TypeScript: `no-shadow`

**Autofixable?** No.
**Risk:** Low.

**Pattern:** rename the inner variable. Prefer renaming the **inner** scope to keep callers stable.

```ts
// before
const result = list.filter(result => result.active);
// after
const result = list.filter(item => item.active);
```

---

## TypeScript: `no-deprecated`

**Autofixable?** No.
**Risk:** Medium (replacement API may behave differently).

**Pattern:**
1. Find the deprecation message — TS shows the recommended replacement in the JSDoc.
2. Replace the call; do not silence.
3. If the replacement requires an API/contract change, **stop and ask the user**.

**Common SkyUX/Angular deprecations:** see `node_modules/@skyux/*/lib/modules/**` JSDoc for `@deprecated` tags.

---

## TypeScript: `explicit-member-accessibility`

**Autofixable?** Yes (`--fix`).
**Risk:** Low.

**Pattern:** add `public`/`private`/`protected` explicitly. Autofix defaults to `public`; for private fields used only inside the class, prefer `private` manually.

---

## TypeScript: `explicit-module-boundary-types`

**Autofixable?** Partial (only when type is obvious).
**Risk:** Low.

**Pattern:** add return type to exported functions.
```ts
// before
export function getId() { return this.id; }
// after
export function getId(): string { return this.id; }
```
For void methods: `: void`. For Observables: `: Observable<T>`. For promises: `: Promise<T>`.

---

## TypeScript: `no-unused-vars`

**Autofixable?** No (potentially destructive).
**Risk:** Medium.

**Pattern:**
1. Remove the import or variable.
2. If it's a function parameter required by an interface, prefix with `_`: `(_event: Event) => ...`.
3. If it's a destructured property you genuinely need to discard: `const { keepThis, ...rest } = obj;`.

**Anti-pattern:** never just comment it out.

---

## TypeScript: `no-floating-promises`

**Autofixable?** No.
**Risk:** Medium (catches real bugs).

**Pattern:**
- Add `await` if the calling function is async.
- Or `void promise;` if you genuinely want fire-and-forget (rare).
- Or `.catch(handler)` to handle rejection explicitly.

Almost always the fix is `await`. If it's not, ask.

---

## TypeScript: `prefer-nullish-coalescing`

**Autofixable?** Yes (`--fix`).
**Risk:** Low when types are strict; medium when types are loose.

**Pattern:** `||` → `??` for default fallbacks where `0` and `""` are valid values.

**Watch out:** autofix may change semantics if the left operand can legitimately be `0` or `""` and the code intended to treat them as "missing". Read the surrounding logic.

---

## TypeScript: `prefer-optional-chain`

**Autofixable?** Yes.
**Risk:** Low.

`a && a.b && a.b.c` → `a?.b?.c`.

---

## TypeScript: `no-redundant-type-constituents`

**Autofixable?** Yes (`--fix`).
**Risk:** Low.

`string | any` → `any`. `string | string` → `string`. Often the right fix is to drop `any` entirely (see `no-explicit-any`).

---

## TypeScript: `no-non-null-asserted-optional-chain`

**Autofixable?** No.
**Risk:** Medium.

`a?.b!` is contradictory. Pattern: drop the `!` and handle the undefined case, **or** drop the `?.` if you have proven `a` is non-null.

---

## Angular: `prefer-inject`

**Autofixable?** Yes (`--fix`) in recent versions.
**Risk:** Low for components, medium for classes used with manual instantiation.

**Pattern:**
```ts
// before
constructor(private svc: MyService) {}
// after
private svc = inject(MyService);
```

**Watch out:** `inject()` must run in an injection context — fine inside class field initializers, broken in plain functions. Don't use it inside helper functions.

---

## Angular: `prefer-standalone`

**Autofixable?** No.
**Risk:** High (architectural).

Migrate component to standalone: drop the `NgModule` registration, add `imports` array. Always run unit tests after. For Allocations frontend specifically, check if the SPA's main module shell is ready for standalone migration before touching individual components.

If unsure → **stop and ask**.

---

## Angular Template: `no-inline-styles`

**Autofixable?** No.
**Risk:** Low.

**Pattern:** move `style="..."` to the component's SCSS as a class.
```html
<!-- before -->
<div style="color: red; padding: 8px;">...</div>
<!-- after -->
<div class="alert-box">...</div>
```
```scss
.alert-box { color: red; padding: 8px; }
```

For dynamic values, use Angular `[style.foo]="expr"` style bindings instead of `style="..."`.

---

## Core ESLint: `eqeqeq`

**Autofixable?** Yes.
**Risk:** Low.

`==` → `===`, `!=` → `!==`. Autofix is safe in TS code (types catch the rare intended-coercion cases).

---

## Core ESLint: `radix`

**Autofixable?** Yes (adds `, 10`).
**Risk:** Low.

`parseInt(x)` → `parseInt(x, 10)`.

---

## Core ESLint: `id-denylist`

**Autofixable?** No.
**Risk:** Low (mechanical rename).

Rename banned identifiers (typically `e`, `err`, `cb`, `data`) to descriptive names. Use VS Code's **Rename Symbol** to update references safely.

---

## Core ESLint: `default-case`

**Autofixable?** No.
**Risk:** Low.

Add `default:` branch to switch. For exhaustive unions, prefer:
```ts
default: {
  const _exhaustive: never = value;
  return _exhaustive;
}
```

---

## Core ESLint: `no-case-declarations`

**Autofixable?** No.
**Risk:** Low.

Wrap case body in `{ }` so `const`/`let` are scoped.

---

## SkyUX: `skyux-eslint-template/no-unbound-id`

**Autofixable?** No.
**Risk:** Low.

Template `id` attribute must be bound. Use `[id]="someUniqueId"` (often a `inputId` input on the component). For Allocations, check existing patterns in similar components.

---

## SkyUX: `skyux-eslint-template/prefer-form-control-component`

**Autofixable?** No.
**Risk:** Medium (markup change).

Wrap form inputs in `<sky-form-field>` or `<sky-input-box>`. Don't strip the existing markup; **add** the wrapper.

---

## Parse errors

**Cause:** file not included in any tsconfig the ESLint parser knows about.

**Pattern:** check `eslint.config.mjs` / `tsconfig.json` for the file pattern. Do not "fix" by adding to tsconfig — that may change build behavior. Report to the user; commonly these are spec files or build scripts intentionally excluded.

---

## When no recipe matches

1. Read the rule's docs (search `eslint.org/docs/latest/rules/<ruleId>` or `typescript-eslint.io/rules/<ruleId>`).
2. Find the smallest example in the docs.
3. Apply it cautiously to **one** message, verify, then scale.
4. Add the new recipe to this file so the next run is faster.
