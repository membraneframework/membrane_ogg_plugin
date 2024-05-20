defmodule Dupa do
  use Membrane.Pipeline

  require Membrane.Logger

  @impl true
  def handle_init(_context, options) do
    IO.inspect(File.cwd())
    Membrane.Logger.debug(File.cwd())

    spec = [
      child(:source, %Membrane.File.Source{location: options.input_file})
      |> child(:debug, %Membrane.Debug.Filter{handle_buffer: &IO.inspect(&1, label: "buffer")})
      |> child(:ogg_demuxer, Membrane.Ogg.Demuxer)
    ]

    {[spec: spec], %{}}
  end

  @impl true
  def handle_child_notification({:new_track, {track_id, codec}}, :ogg_demuxer, _context, state) do
    case codec do
      :opus ->
        spec = [
          get_child(:ogg_demuxer)
          |> via_out(Pad.ref(:output, track_id))
          |> child(:parser, %Membrane.Opus.Parser{delimitation: :delimit})
          |> child(:sink, %Membrane.File.Sink{
            location: "test/fixtures/in_opus_delimitted.opus"
          })
        ]

        {[spec: spec], state}
    end
  end
end

defmodule Dupa2 do
  use Membrane.Pipeline

  require Membrane.Logger

  @impl true
  def handle_init(_context, _options) do
    IO.inspect(File.cwd())
    Membrane.Logger.debug(File.cwd())

    spec = [
      child(:source, %Membrane.File.Source{location: "test/fixtures/in_opus_delimitted.opus"})
      |> child(:parser, %Membrane.Opus.Parser{input_delimitted?: true, delimitation: :undelimit})
      |> child(:decoder, Membrane.Opus.Decoder)
      |> child(:player, Membrane.PortAudio.Sink)
    ]

    {[spec: spec], %{}}
  end
end

defmodule Dupa3 do
  use Membrane.Pipeline

  require Membrane.Logger

  @impl true
  def handle_init(_context, _options) do
    IO.inspect(File.cwd())
    Membrane.Logger.debug(File.cwd())

    spec = [
      child(:source, %Membrane.File.Source{location: "test/fixtures/in_opus_delimitted.opus"})
      |> child(:parser, %Membrane.Opus.Parser{
        input_delimitted?: true,
        delimitation: :undelimit,
        generate_best_effort_timestamps?: true
      })
      |> child(:decoder, Membrane.Ogg.Muxer)
      |> child(:sink, %Membrane.File.Sink{location: "tmp/dupa.ogg"})
    ]

    {[spec: spec], %{}}
  end
end
