# ALCops for AL-Go

> **⚠️ Deprecated**: This script-based approach is deprecated. Please migrate to the CLI-based approach using `@alcops/core`.
>
> 👉 **[Migration guide](https://alcops.dev/docs/getting-started/cicd/github/#2-create-the-initialization-script)**

---

Run [ALCops](https://alcops.dev/) custom code analyzers in your [AL-Go](https://github.com/microsoft/AL-Go) pipelines, with a single script hook.

## What this does

AL-Go supports custom pipeline hooks that run at specific stages of a build. This repo provides an installer script that plugs into AL-Go though the **PipelineInitialize.ps1** hook to automatically download and configure ALCops analyzers before compilation starts.

## Quick start

> **⚠️ Deprecated**: Use the [CLI-based initialization script](https://alcops.dev/docs/getting-started/cicd/github/#2-create-the-initialization-script) instead.

1. Create a file called `PipelineInitialize.ps1` in your `.AL-Go` folder.
2. Add the following content:

```PS
Param([Hashtable] $parameters)

# Configuration
$scriptUrl = "https://raw.githubusercontent.com/ALCops/AL-Go/v1.0.0/scripts/Install-ALCops.ps1"

# Download and run the installer script
$scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) "Install-ALCops.ps1"
Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath -UseBasicParsing

& $scriptPath
```

### Configuration options

| Parameter | Default | Description |
|---|---|---|
| `$packageVersion` | `""` | Version channel: `""` (latest stable), `"alpha"`, `"beta"`, or an exact version like `"1.2.3"` |
| `$targetFramework` | `net8.0` | Leave blank for current AL Language versions. Set to `netstandard2.1` for AL Language versions below v16.0. |

## How it works

When AL-Go runs the PipelineInitialize hook, the script:

1. Downloads `Install-ALCops.ps1` from this repo.
2. The installer resolves the requested analyzer package version from NuGet.
3. Extracts the analyzer DLLs into the workspace so AL-Go picks them up as custom code cops.

## Learn more

For detailed documentation, rule descriptions, and configuration guidance, visit **[alcops.dev](https://alcops.dev/)**.

## License

[MIT](LICENSE)
