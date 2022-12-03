defmodule Membrane.Ogg.DemuxerTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.Testing

  @fixtures_dir "./test/fixtures/"

  defmodule TestPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_context, options) do
      structure = [
        child(:source, %Membrane.File.Source{
          location: options.input_file,
          chunk_size: 4096
        }),
        child(:ogg_demuxer, Membrane.Ogg.Demuxer),
        get_child(:source)
        |> get_child(:ogg_demuxer)
      ]

      state = %{output_dir: options.output_dir, track_id_to_file: options.track_id_to_output_file}

      {[spec: structure, playback: :playing], state}
    end

    @impl true
    def handle_child_notification({:new_track, {track_id, codec}}, :ogg_demuxer, _context, state) do
      output_file = state.track_id_to_file[track_id]

      case codec do
        :opus ->
          structure = [
            child(:sink, %Membrane.File.Sink{
              location: Path.join(state.output_dir, output_file)
            }),
            get_child(:ogg_demuxer)
            |> via_out(Pad.ref(:output, track_id))
            |> get_child(:sink)
          ]

          {[spec: structure, playback: :playing], state}
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

    assert_pipeline_play(pipeline)

    assert_end_of_stream(pipeline, :sink)

    Testing.Pipeline.terminate(pipeline, blocking?: true)

    for reference <- Map.values(track_id_to_reference) do
      reference_file = File.read!(Path.join(@fixtures_dir, reference))
      result_file = File.read!(Path.join(tmp_dir, reference))

      assert byte_size(reference_file) == byte_size(result_file),
             "#{reference} #{byte_size(reference_file)} == #{byte_size(result_file)}"

      assert reference_file == result_file, "#{reference} not same files"
    end
  end

  @tag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      :ok
    end)
  end

  @tag :tmp_dir
  test "demuxing ogg containing opus", %{tmp_dir: tmp_dir} do
    # 4_210_672_757 = track id in test_fixtures_1.ogg
    test_stream("test_fixtures_1.ogg", %{4_210_672_757 => "test_fixtures_1.opus"}, tmp_dir)
  end
end
