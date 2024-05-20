defmodule Membrane.Ogg.Demuxer do
  @moduledoc """
  A Membrane Element for demuxing an Ogg.

  For now it supports only Ogg containing a single Opus track.

  All the tracks in the Ogg must have a corresponding output pad linked (`Pad.ref(:output, track_id)`).
  """
  use Membrane.Filter
  require Membrane.Logger
  alias Membrane.Ogg.Parser
  alias Membrane.Ogg.Parser.Packet
  alias Membrane.{Buffer, Opus, RemoteStream}

  def_input_pad :input,
    flow_control: :auto,
    accepted_format: %RemoteStream{content_format: format} when format in [nil, Ogg]

  def_output_pad :output,
    flow_control: :auto,
    accepted_format: %RemoteStream{type: :packetized, content_format: Opus}

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            parser_acc: binary(),
            continued_packet: binary(),
            received_bos_packet: boolean()
          }

    defstruct parser_acc: <<>>,
              continued_packet: nil,
              received_bos_packet: false
  end

  @impl true
  def handle_init(_ctx, _options) do
    {[], %State{}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, %RemoteStream{type: :packetized, content_format: Opus}}], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_buffer(:input, %Buffer{payload: bytes}, _ctx, state) do
    rest = state.parser_acc <> bytes

    {parsed, new_continued_packet, rest} =
      Parser.parse(rest, state.continued_packet)

    state = %State{
      state
      | parser_acc: rest,
        continued_packet: new_continued_packet
    }

    get_packet_actions(parsed, state)
  end

  defp get_packet_actions(packets_list, state) do
    {actions, packets_containing_bos_packet} =
      Enum.flat_map_reduce(packets_list, state.received_bos_packet, &get_packet_action/2)

    {actions, %State{state | received_bos_packet: packets_containing_bos_packet}}
  end

  defp get_packet_action(packet, received_bos_packet) do
    case packet do
      %Packet{bos?: true, payload: <<"OpusHead", _rest::binary>>} ->
        if received_bos_packet do
          raise "Multiple Opus streams in the input Ogg stream, currently unsupported"
        end

        {[], true}

      %Packet{bos?: true, payload: _not_opushead} ->
        raise "Invalid bos packet, probably unsupported codec."

      %Packet{eos?: true, payload: <<>>} ->
        {[], received_bos_packet}

      %Packet{payload: <<"OpusTags", _rest::binary>>} ->
        {[], received_bos_packet}

      %Packet{payload: data_payload} ->
        {[buffer: {:output, %Buffer{payload: data_payload}}], received_bos_packet}
    end
  end
end
