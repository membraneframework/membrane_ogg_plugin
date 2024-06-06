defmodule Membrane.Ogg.Opus do
  @moduledoc false

  require Membrane.Logger

  @id_header_signature "OpusHead"
  @version 1
  @preskip 0
  @sample_rate 48_000
  @output_gain 0
  @channel_mapping_family 0

  @comment_header_signature "OpusTags"
  @vendor "membraneframework"
  @user_comment_list_length 0

  @plc_packet_for_2_5ms_gap <<16::5, 0::1, 0::3>>
  @shortest_frame_duration Membrane.Time.microseconds(2_500)

  @type plc_packet :: %{
          payload: binary(),
          pts: Membrane.Time.t(),
          metadata: %{duration: Membrane.Time.non_neg()}
        }

  @spec create_id_header(non_neg_integer()) :: binary()
  def create_id_header(channel_count) do
    <<@id_header_signature, @version, channel_count, @preskip::little-16, @sample_rate::little-32,
      @output_gain::little-16, @channel_mapping_family>>
  end

  @spec create_comment_header() :: binary()
  def create_comment_header() do
    <<@comment_header_signature, byte_size(@vendor)::little-32, @vendor,
      @user_comment_list_length::little-32>>
  end

  @spec create_plc_packets(Membrane.Time.t(), Membrane.Time.t()) :: [plc_packet()]
  def create_plc_packets(gap_start_timestamp, gap_duration) do
    # PLC: Packet Loss Concealment
    if rem(gap_duration, @shortest_frame_duration) != 0 do
      Membrane.Logger.warning(
        "Theoretically impossible gap in Opus stream of #{Membrane.Time.as_milliseconds(gap_duration, :exact) |> Ratio.to_float()}ms"
      )
    end

    # Adding a millisecond margin in case of timestamp innacuracies
    packets_to_generate =
      div(gap_duration + Membrane.Time.millisecond(), @shortest_frame_duration)

    Range.to_list(0..(packets_to_generate - 1))
    |> Enum.map(
      &%{
        payload: @plc_packet_for_2_5ms_gap,
        pts: gap_start_timestamp + &1 * @shortest_frame_duration,
        metadata: %{duration: @shortest_frame_duration}
      }
    )
  end
end
