
Mix.install([
  {:membrane_core, "~> 0.11.0"},
  {:membrane_opus_format, "~> 0.3.0"},
  {:crc, "~> 0.10"},
  {:membrane_file_plugin, "~> 0.13.1"},
  {:membrane_portaudio_plugin,
    git: "https://github.com/membraneframework/membrane_portaudio_plugin.git",
    branch: "bugfix/rename_playback_state_to_playback"},
  {:membrane_opus_plugin, "~> 0.16.0"},
  {:membrane_ogg_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()},
])

defmodule DemuxerExample do
  use Membrane.Pipeline

  @impl true
  def handle_init(_context, _opts) do
    structure = [
      child(:source, %Membrane.File.Source{
        location: "./test/fixtures/test_fixtures_1.ogg"
      }) |>
      child(:ogg_demuxer, Membrane.Ogg.Demuxer)
    ]

    {[spec: structure, playback: :playing], %{}}
  end

  @impl true
  def handle_child_notification({:new_track, {track_id, codec}}, :ogg_demuxer, _context, state) do
    case codec do
      :opus ->
        structure = [
          get_child(:ogg_demuxer)
          |> via_out(Pad.ref(:output, track_id))
          |> child(:opus, Membrane.Opus.Decoder)
          |> child(:portaudio, Membrane.PortAudio.Sink)
        ]

        {[spec: structure, playback: :playing], state}
    end
  end
end

{:ok, sup_pid, pid}  =  DemuxerExample.start_link()
