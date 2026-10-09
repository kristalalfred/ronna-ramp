# Ronna plugin for Ramp

The client-side Lua plugin for Ronna. It adds hosted session discovery, launchers,
email sign-in, workspace and runner selection, and Ronna's session interface.
It requires the Ramp and Ronna binaries. Git distributes this plugin; Homebrew
distributes binaries separately.

## Install

The [Ramp starter](https://github.com/KristalAlfred/ramp-starter) installs and
configures this plugin. To add it to an existing configuration instead:

```sh
git clone --branch v0.1.0 --depth 1 \
  https://github.com/KristalAlfred/ronna-ramp \
  ~/.local/share/ramp/plugins/ronna
```

Add this to `~/.config/ramp/init.lua`:

```lua
ramp.api.add_plugin('~/.local/share/ramp/plugins/ronna')
require('ronna').setup({
  args = { '--control', 'https://ronna.svartkonst.com' },
  launch_args = { '--provider-default-resources' },
  network_mode = 'selected-integrations',
})
```

`RONNA_BIN` overrides the `ronna` executable on PATH. An invited account is
required for the hosted server. The plugin opens email sign-in when you are
signed out; `:ronna-login` opens it explicitly.

## Composition

`setup(opts)` runs once per configuration load. Calling it from your configuration
sets the options before `plugin/ronna.lua` runs. Set `default_ui = false` to keep
another plugin's session interface, `runner_picker = false` to disable runner
selection, or `signin_ui = false` to handle sign-in separately. `binary`, `args`,
`launch_args`, `network_mode`, and `prewarm_chars` configure CLI invocation and
launch behavior.

The package can also be placed in a normal Ramp `pack/*/start/*` directory. It
then loads automatically, including when there is no user configuration.

## Maintenance

This repository publishes the Ronna-owned client adapter from
`code/adapters/ramp/ronna` in the private Ronna repository. `upstream.txt` records
the source revision. Make adapter changes in Ronna, then synchronize only the
tracked Lua files:

```sh
just sync /path/to/ronna
```

Verify the updated plugin with the Ramp starter's `just check`, review and commit
the synchronized files, and publish a release tag. This repository contains no
server code or credentials.
