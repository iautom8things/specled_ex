<!-- agent-rules: generated v0.13.1 -->
---
description: Elixir language patterns. Timeouts, behaviour impls, list access, immutability, guards, OTP primitives.
# Writing conventions only — paths cover ~every file, so native read-triggered
# loading made this effectively always-on. write_only limits it to edits.
write_only: true
paths:
  - "lib/**/*.ex"
  - "test/**/*.ex"
  - "test/**/*.exs"
---

## Timeouts

Use `to_timeout/1` — never `:timer` functions:
- `to_timeout(minute: 5)` not `:timer.minutes(5)`
- `to_timeout(second: 4)` not `:timer.seconds(4)`

## Behaviour Implementations

Always explicit — never `@impl true`. Reference the behaviour module being implemented:
- `@impl GenServer`
- `@impl Oban.Pro.Worker`
- `@impl MyApp.SomeBehaviour`

## Documentation Strings

When `@moduledoc` or `@doc` examples include string interpolation markers
(`#{}`), hashtags (`#`), or similar literal text, escape them so Elixir does
not try to interpolate the docs at compile time:

    # INVALID - attempts to interpolate at compile time
    @doc """
    Items are named: "#{app_name} - Heroku Database"
    We use the #dev-portals vault for portal databases.
    """

    # VALID - escape interpolation while keeping ordinary docs readable
    @doc """
    Items are named: `\#{app_name} - Heroku Database`
    We use the `#dev-portals` vault for portal databases.
    """

Single-quoted heredocs also avoid interpolation:

    @moduledoc '''
    Items are named: "#{app_name} - Heroku Database"
    We use the #dev-portals vault.
    '''

## List Access

Lists don't support `list[i]`. Use `Enum.at/2`, pattern matching, or the `List` module.

## Variable Binding In Blocks

Variables rebound inside `if`/`case`/`cond` don't escape the block. Bind the result:

    # INVALID
    if connected?(socket) do
      socket = assign(socket, :val, val)
    end

    # VALID
    socket = if connected?(socket) do
      assign(socket, :val, val)
    end

## Module Structure

Never nest multiple modules in the same file — causes cyclic dependencies and compile errors.

## Struct Field Access

Never use map access syntax (`struct[:field]`) on structs — they don't implement `Access` by default.
Use `my_struct.field` or the struct's API (e.g. `Ecto.Changeset.get_field/2`).

## Conditionals

No `else if` or `elsif` in Elixir. Use `cond` or `case` for multiple branches.

## Predicate Naming

Predicate functions end in `?`. Reserve `is_*` names for guards.

## Safety

Never use `String.to_atom/1` on user input — memory leak risk.

## Concurrency

Use `Task.async_stream(collection, callback, timeout: :infinity)` for concurrent enumeration with back-pressure.

## OTP Primitives

Named processes require `name:` in the child spec:

    {DynamicSupervisor, name: MyApp.DynSup}
    DynamicSupervisor.start_child(MyApp.DynSup, child_spec)
