defmodule Membrane.Ogg.DemuxerTest do
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
        |> child(:ogg_demuxer, Membrane.Ogg.Demuxer)
      ]

      state = %{output_dir: options.output_dir, track_id_to_file: options.track_id_to_output_file}

      {[spec: spec], state}
    end

    @impl true
    def handle_child_notification({:new_track, {track_id, codec}}, :ogg_demuxer, _context, state) do
      output_file = state.track_id_to_file[track_id]

      case codec do
        :opus ->
          spec = [
            get_child(:ogg_demuxer)
            |> via_out(Pad.ref(:output, track_id))
            |> child(%Membrane.Opus.Parser{generate_best_effort_timestamps?: true})
            |> child(%Membrane.Debug.Filter{
              handle_buffer: fn buffer ->
                assert buffer.metadata.ogg_page_pts in [nil, buffer.pts]
              end
            })
            |> child(:sink, %Membrane.File.Sink{
              location: Path.join(state.output_dir, output_file)
            })
          ]

          {[spec: spec], state}
      end
    end
  end

  defp test_stream(input_file, track_id_to_reference, tmp_dir) do
    pipeline =
      [
        module: TestPipeline,
        custom_args: %{
          input_file: Path.join(@fixtures_dir, input_file),
          output_dir: tmp_dir,
          track_id_to_output_file: track_id_to_reference
        }
      ]
      |> Testing.Pipeline.start_link_supervised!()

    assert_end_of_stream(pipeline, :sink)

    Testing.Pipeline.terminate(pipeline)

    for reference <- Map.values(track_id_to_reference) do
      reference_file = File.read!(Path.join(@fixtures_dir, reference))
      result_file = File.read!(Path.join(tmp_dir, reference))

      assert reference_file == result_file
    end
  end

  @tag :tmp_dir
  test "demuxing ogg containing opus", %{tmp_dir: tmp_dir} do
    # 4_210_672_757 = track id in in_opus.ogg
    test_stream("in_opus.ogg", %{4_210_672_757 => "ref_opus.opus"}, tmp_dir)
  end
end
