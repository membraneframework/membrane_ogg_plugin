defmodule Membrane.Ogg.Opus.Packet do
  @moduledoc false

  @plc_packet_for_2_5ms_gap <<16::5, 0::1, 0::3>>
  @shortest_frame_duration Membrane.Time.microseconds(2_500)

  @type plc_packet :: %{
          payload: binary(),
          pts: Membrane.Time.t(),
          metadata: %{duration: Membrane.Time.non_neg()}
        }

  @spec create_plc_packets(Membrane.Time.t(), Membrane.Time.t()) :: [plc_packet()]
  def create_plc_packets(gap_start_timestamp, gap_duration) do
    # PLC = Packet Loss Concealment
    if rem(gap_duration, @shortest_frame_duration) != 0, do: raise("Unrecoverable gap")

    packets_to_generate = div(gap_duration, @shortest_frame_duration)

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
