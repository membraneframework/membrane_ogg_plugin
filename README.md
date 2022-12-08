# Membrane Ogg Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_ogg_plugin.svg)](https://hex.pm/packages/membrane_ogg_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_ogg_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_ogg_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_ogg_plugin)

Plugin for depayloading an Ogg file into an Opus stream.

It is part of [Membrane Multimedia Framework](https://membraneframework.org).

## Installation

The package can be installed by adding `membrane_ogg_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_ogg_plugin, "~> 0.1.0"}
  ]
end
```

## Usage

### `Membrane.Ogg.Demuxer`

For an example see `examples/demuxer_example.exs`. To run the example you can use the following command:

```iex examples/demuxer_example.exs```

On macOS you might need to set the opus include path like this:

```export C_INCLUDE_PATH=/opt/homebrew/Cellar/opus/1.3.1/include/```

## Copyright and License

Copyright 2022, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_ogg_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_ogg_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
