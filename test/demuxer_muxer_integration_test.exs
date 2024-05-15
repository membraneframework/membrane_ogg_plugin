defmodule Membrane.Ogg.DemuxerMuxerTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions

  alias Membrane.Testing

  @fixtures_dir "./test/fixtures/"

  defmodule TestPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_context, options) do
      spec = [
        child(:source, %Membrane.File.Source{location: options.input_file})
        |> child(:demuxer, Membrane.Ogg.Demuxer)
      ]

      state = %{output_dir: options.output_dir}

      {[spec: spec], state}
    end

    @impl true
    def handle_child_notification({:new_track, {track_id, :opus}}, :demuxer, _context, state) do
      spec = [
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, track_id))
        |> child(:parser, Membrane.Opus.Parser)
        |> child(:muxer, Membrane.OGG.Muxer)
        |> child(:sink, %Membrane.File.Sink{
          location: Path.join(state.output_dir, "out_opus.ogg")
        })
      ]

      {[spec: spec], state}
    end
  end

  defp test_stream(input_file, tmp_dir) do
    pipeline =
      [
        module: TestPipeline,
        custom_args: %{
          input_file: Path.join(@fixtures_dir, input_file),
          output_dir: tmp_dir
        }
      ]
      |> Testing.Pipeline.start_link_supervised!()

    assert_end_of_stream(pipeline, :sink)

    Testing.Pipeline.terminate(pipeline)

    # for reference <- Map.values(track_id_to_reference) do
    #   reference_file = File.read!(Path.join(@fixtures_dir, reference))
    #   result_file = File.read!(Path.join(tmp_dir, reference))

    #   assert reference_file == result_file
    # end
  end

  @tag :tmp_dir
  test "demuxing ogg containing opus and muxing again", %{tmp_dir: tmp_dir} do
    # 4_210_672_757 = track id in in_opus.ogg
    test_stream("in_opus.ogg", tmp_dir)
  end
end
