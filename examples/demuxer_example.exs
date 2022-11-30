
Mix.install([
  :membrane_core,
  :membrane_opus_format,
  :membrane_file_plugin,
  {:membrane_portaudio_plugin,
    git: "https://github.com/membraneframework/membrane_portaudio_plugin.git",
    branch: "bugfix/rename_playback_state_to_playback"},
  {:membrane_opus_plugin,
    git: "https://github.com/membraneframework/membrane_opus_plugin.git", branch: "core-v0.11"}
])

defmodule DemuxerExample do
  use Membrane.Pipeline

  @impl true
  def handle_init(_context, _opts) do
    structure = [
      child(:source, %Membrane.File.Source{
        location: "test_fixtures_2.ogg"
      }),
      child(:ogg_demuxer, Membrane.Ogg.Demuxer),
      get_child(:source)
      |> get_child(:ogg_demuxer)
    ]

    {[spec: structure, playback: :playing], %{}}
  end

  @impl true
  def handle_child_notification({:new_track, {track_id, codec}}, :ogg_demuxer, _context, state) do
    case codec do
      :opus ->
        structure = [
          child(:opus, Membrane.Opus.Decoder),
          child(:portaudio, Membrane.PortAudio.Sink),
          get_child(:ogg_demuxer)
          |> via_out(Pad.ref(:output, track_id))
          |> get_child(:opus)
          |> get_child(:portaudio)
        ]

        {[spec: structure, playback: :playing], state}
    end
  end
end

{:ok, sup_pid, pid}  =  DemuxerExample.start_link()
