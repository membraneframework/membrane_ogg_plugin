defmodule Membrane.Ogg.MuxerTest do
  use ExUnit.Case, async: false

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec
  alias Membrane.Testing

  @fixtures_dir "./test/fixtures/"

  defp test_stream(input_file, ref_file, output_file, tmp_dir) do
    spec = [
      child(:source, %Membrane.File.Source{location: Path.join(@fixtures_dir, input_file)})
      |> child(:parser, %Membrane.Opus.Parser{
        generate_best_effort_timestamps?: true,
        delimitation: :undelimit,
        input_delimitted?: true
      })
      |> child(:ogg_demuxer, Membrane.Ogg.Muxer)
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
  test "muxing opus into ogg", %{tmp_dir: tmp_dir} do
    test_stream("in_opus_delimited.opus", "ref_opus.ogg", "out_opus.ogg", tmp_dir)
  end
end
