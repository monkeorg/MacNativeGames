# Linux cloud tools

Run setup mode only when package installation is authorized; it is prepared but not executed during the current no-installs goal. Command mode still requires the usual authorization for the command being run.

The repository helper prepares project-local source tools after the checkout is available:

```sh
bash .codex/setup.sh
```

It derives the checkout from its own location, creates or reuses `games/totk/.venv`, and installs Python **3.14.8**, the directly pinned packages in `games/totk/requirements.txt`, CMake **3.31.10** and Ninja **1.13.2**. It does not install `requirements-dev.txt`, run tests/probes/builds, change system Python, or install system packages. Transitive dependencies follow the requirements' dependency constraints; this is not a complete transitive lockfile.

For a persistent environment outside the checkout, set an absolute path consistently for setup and command use. For example, to reuse the already prepared workspace environment:

```sh
MACNATIVEGAMES_ENV=/workspace/.venvs/macnativegames bash .codex/setup.sh
MACNATIVEGAMES_ENV=/workspace/.venvs/macnativegames bash .codex/setup.sh -- python --version
```

The `-- command ...` form only checks and uses an existing Python 3.14.8 virtual environment; it does not install or refresh dependencies. It prepends that environment's `bin` directory to inherited `PATH` and sets `VIRTUAL_ENV` for the child command. It preserves proxy, CA and authentication settings. Commands are the caller's choice; this helper does not make tests or device actions permissible during a no-tests task.

Repeated setup reuses a matching virtual environment and lets uv retain satisfied packages. An incompatible environment, broken symlink or occupied path without a virtual environment is refused without deletion. A user-selected existing virtual environment must disable system site packages; setup reconciles the requested package versions inside it, so choose a dedicated project environment. Existing symlinks to a valid environment are followed but never replaced. The helper does not create or replace other environment links.

## Managed configuration boundary

The selected Linux image must already provide **uv**. Clang is a separate image prerequisite for native source compilation; arrange it through the supported managed-image package configuration. `pkg-config` may also be needed for native dependency builds. The helper contains no `sudo`, `apt`, permission changes, credentials or network-policy changes. Its pinned CMake/Ninja packages remove the need to replace system versions merely for this setup.

On 2026-10-25, `/workspace/.venvs/macnativegames` already held the requested tools and `/workspace/MacNativeGames/games/totk/.venv` pointed there. Those are observations of a workspace installation, not a persisted image/startup setting. Current managed tools expose runtime inspection but no supported configuration mutation API; committing this helper does **not** register it as a startup hook. A supported environment configuration editor must still select the image prerequisites and register `bash .codex/setup.sh` (with any desired `MACNATIVEGAMES_ENV`) after checkout. Do not edit `/etc/codex/network-policy.json`; it is an observed snapshot, not that configuration interface.

This helper and its documentation were prepared by source review only. They were not executed; the existing workspace environment was not reinstalled or modified. No tests, probes, simulators or builds were run for this change. Apple SDK compilation, signed app builds and physical-device acceptance remain separate capabilities; Linux tool setup cannot provide them. See [the iPad build boundary](ipados-build.md) and [device acceptance](ipados-acceptance.md).
