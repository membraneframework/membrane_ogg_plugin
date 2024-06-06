Mix.install([
  {:membrane_file_plugin, "~> 0.16.0"},
  {:membrane_portaudio_plugin, "~> 0.18.0"},
  {:membrane_opus_plugin, "~> 0.20.0"},
  {:membrane_ogg_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()},
])

defmodule DemuxerExample do
  use Membrane.Pipeline

  @impl true
  def handle_init(_context, _opts) do
    structure = [
      child(:source, %Membrane.File.Source{
        location: "./test/fixtures/in_opus.ogg"
      })
      |> child(:ogg_demuxer, Membrane.Ogg.Demuxer)
      |> child(:opus, Membrane.Opus.Decoder)
      |> child(:portaudio, Membrane.PortAudio.Sink)
    ]

    {[spec: structure], %{}}
  end

  @impl true
  def handle_element_end_of_stream(:portaudio, _pad, _ctx, state) do
    {[terminate: :normal], state}
  end

  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end
end

{:ok, _supervisor_pid, pipeline_pid} = Membrane.Pipeline.start(DemuxerExample)
ref = Process.monitor(pipeline_pid)

# Wait for the pipeline to finish
receive do
  {:DOWN, ^ref, :process, _pipeline_pid, _reason} ->
    :ok
end
