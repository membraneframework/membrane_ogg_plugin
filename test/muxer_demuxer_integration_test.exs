defmodule Membrane.Ogg.MuxerDemuxerTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec
  alias Membrane.Testing

  @fixtures_dir "./test/fixtures/"

  defp test_stream(input_file, ref_file, output_file, tmp_dir) do
    spec = [
      child(:source, %Membrane.File.Source{location: Path.join(@fixtures_dir, input_file)})
      |> child(:undelimiter_parser, %Membrane.Opus.Parser{
        input_delimitted?: true,
        delimitation: :undelimit,
        generate_best_effort_timestamps?: true
      })
      |> child(:ogg_muxer, Membrane.Ogg.Muxer)
      |> child(:ogg_demuxer, Membrane.Ogg.Demuxer)
      |> child(:delimiter_parser, %Membrane.Opus.Parser{
        delimitation: :delimit
      })
      |> child(:sink, %Membrane.File.Sink{
        location: Path.join(tmp_dir, output_file)
      })
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_end_of_stream(pipeline, :sink)

    Testing.Pipeline.terminate(pipeline)

    reference_file = File.read!(Path.join(@fixtures_dir, ref_file))
    result_file = File.read!(Path.join(tmp_dir, output_file))

    assert reference_file == result_file
  end

  @tag :tmp_dir
  test "demuxing ogg containing opus and muxing it again", %{tmp_dir: tmp_dir} do
    test_stream("in_opus_delimited.opus", "in_opus_delimited.opus", "out_opus.opus", tmp_dir)
  end
end
