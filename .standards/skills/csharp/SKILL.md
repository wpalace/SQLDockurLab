---
name: csharp
description: "House coding standard for C# 14 / .NET 10. Use when writing, editing, or reviewing C# code (*.cs, *.csproj, *.sln, *.slnx, Directory.Build.props, .editorconfig)."
---

# C# Standards

> **Before calling work done:** run the formatter and linter checks in the Formatting section (`dotnet format --verify-no-changes`) and fix every finding. Reference config: `.editorconfig` beside this file, which `sync-standards.sh` installs at the project root.

**Targets:** C# 14 on .NET 10 LTS (10.0.x, supported until Nov 2028). Evaluate .NET 11 and C# 15 (STS, GA expected Nov 2026) for new services only.

The compiler and analyzers are your first reviewers, so configure them strictly.

## Naming

| Element | Convention | Example |
|---|---|---|
| Types, methods, properties, constants | PascalCase | `OrderService`, `MaxRetries` |
| Interfaces | `I` + PascalCase | `IOrderRepository` |
| Locals, parameters | camelCase | `orderId`, `customer` |
| Private fields | `_camelCase` | `_logger`, `_repository` |
| Async methods | `Async` suffix | `GetOrderAsync` |

- Use file-scoped namespaces and one public type per file. Use `var` when the type is obvious.

## Project Settings

Put these in `Directory.Build.props`. Manage package versions centrally in `Directory.Packages.props`.

```xml
<PropertyGroup>
  <TargetFramework>net10.0</TargetFramework>
  <Nullable>enable</Nullable>
  <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  <AnalysisLevel>latest-recommended</AnalysisLevel>
  <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
</PropertyGroup>
```


## Formatting

Code is formatted for human readability and review. A formatter settles layout so reviewers can focus on logic.

- Commit an `.editorconfig` that sets the rules: 4-space indent, Allman braces, `using` directives sorted with `System` first, and file-scoped namespaces.
- CI runs `dotnet format --verify-no-changes`. Set `EnforceCodeStyleInBuild` to `true` so IDE rules fail the build.
- Keep lines under 120 characters. Put one statement and one declaration per line, and always use braces, even for one-line `if` statements.
- Put long argument lists one per line. Put fluent and LINQ chains one call per line, with the leading `.`.
- Use trailing commas in multi-line initializers, collection expressions, and enums.
- Separate members and logical blocks with one blank line. Order members as fields, constructors, properties, then methods.
- Comments and XML docs explain *why* and the contract. Don't comment out code; delete it. Keep reformatting PRs separate from logic changes.

```ini
[*.cs]
indent_size = 4
csharp_new_line_before_open_brace = all
dotnet_sort_system_directives_first = true
csharp_style_namespace_declarations = file_scoped:error
csharp_prefer_braces = true:error
```

```csharp
// Before
var client = new ApiClient(httpClient, options.BaseUrl, TimeSpan.FromSeconds(30), retryPolicy, logger);

// After
var client = new ApiClient(
    httpClient,
    options.BaseUrl,
    timeout: TimeSpan.FromSeconds(30),
    retryPolicy,
    logger);
```

## Nullable Reference Types

- Use `?` only for types that really can be null. Validate inputs with `ArgumentNullException.ThrowIfNull`.
- Every null-forgiving `!` needs a justifying comment.

## Modern Language Features (C# 12 to 14)

- **`field` keyword** (C# 14): add validation to auto-properties without a backing field.
- **Extension blocks** (C# 14): group extension methods *and properties* by receiver. Use them for new extensions.
- **Null-conditional assignment** (C# 14): `customer?.LastSeen = now;`
- **Primary constructors** and **collection expressions** (C# 12): `int[] ids = [1, 2, 3];`
- Prefer `record` for immutable data and `sealed` for classes that aren't designed for inheritance.

```csharp
public string Name
{
    get;
    set => field = value?.Trim() ?? throw new ArgumentNullException(nameof(value));
}

public static class EnumerableExtensions
{
    extension<T>(IEnumerable<T> source)
    {
        public bool IsEmpty => !source.Any();
    }
}
```

## Async/Await

- Go async all the way down. Return `Task` or `Task<T>`, and end the method name in `Async`.
- Accept a `CancellationToken` as the last parameter of every async public API, and pass it through.
- Use `ConfigureAwait(false)` in **library** code. ASP.NET Core application code doesn't need it.
- Use `ValueTask` only on measured hot paths. Use `await foreach` with `IAsyncEnumerable<T>` for streams.

```csharp
public async Task<Order?> GetOrderAsync(int id, CancellationToken ct = default) =>
    await _db.Orders.AsNoTracking()
        .FirstOrDefaultAsync(o => o.Id == id, ct)
        .ConfigureAwait(false);
```

## LINQ vs Loops

- Use LINQ for declarative queries. Use `foreach` when there are side effects, complex logic, or measured hot paths.
- Don't enumerate an `IEnumerable` more than once. Keep EF Core queries `IQueryable` until the final call.
- Use EF Core 10's `LeftJoin` and `RightJoin` instead of `GroupJoin`/`DefaultIfEmpty` gymnastics.

## Dependency Injection

- Use **constructor injection** only, through primary constructors. Don't use service locators in business code.
- Pick lifetimes deliberately: `Singleton` for thread-safe stateless services, `Scoped` for per-request work (`DbContext`), and `Transient` for lightweight services. Never inject a scoped service into a singleton.
- Bind configuration with `IOptions<T>` plus `ValidateOnStart()`. Inject `TimeProvider` instead of reading `DateTime.Now`.

```csharp
public sealed class OrderService(IOrderRepository repository, ILogger<OrderService> logger)
{
    public Task<Order?> FindAsync(int id, CancellationToken ct) => repository.GetAsync(id, ct);
}
```

## Scripts & Tooling

- Use .NET 10 **file-based apps** for small utilities instead of PowerShell or Python when the team owns the C# code: `dotnet run tool.cs`, with `#:package` directives. Promote them with `dotnet project convert` once they grow.

```csharp
#!/usr/bin/env dotnet
#:package Spectre.Console@0.*
Spectre.Console.AnsiConsole.MarkupLine("[green]Done[/]");
```

## Avoid

- **`async void`.** The only exception is event handlers.
- **`.Result`, `.Wait()`, and `.GetAwaiter().GetResult()`.** They cause deadlocks and starvation. Use `await`.
- **Magic strings.** Use `nameof()`, constants, enums, or options classes.

```csharp
throw new ArgumentException("Invalid id", nameof(customerId));
```

- `throw ex;` (use `throw;`), swallowed exceptions, `public` fields, and mutable static state.

## Sources

- Anton Martyniuk, "New Features in .NET 10 and C# 14" (Medium/CodeX, Nov 11, 2025)
- Shubham Kumar, "What's New in .NET 10 and C# 14: A Modern Practitioner's Take" (Medium, Nov 2025)
- Microsoft Learn, "What's new in C# 14"
