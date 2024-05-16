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
    availability: :on_request,
    flow_control: :auto,
    accepted_format: %RemoteStream{type: :packetized, content_format: Opus}

  @typedoc """
  Notification sent when a new track is identified in the Ogg.
  Upon receiving the notification a `Pad.ref(:output, track_id)` pad should be linked.
  """
  @type new_track() ::
          {:new_track, {track_id :: non_neg_integer(), track_type :: atom()}}

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            buffer_actions: [Membrane.Element.Action.t()],
            parser_acc: binary(),
            phase: :all_outputs_linked | :awaiting_linking | :end_of_stream,
            track_states: Parser.track_states()
          }

    defstruct buffer_actions: [],
              parser_acc: <<>>,
              phase: :awaiting_linking,
              track_states: %{}
  end

  @impl true
  def handle_init(_ctx, _options) do
    {[], %State{}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, id) = pad, _context, state) do
    stream_format = {Pad.ref(:output, id), %RemoteStream{type: :packetized, content_format: Opus}}

    case state.phase do
      :awaiting_linking ->
        {
          [{:stream_format, stream_format} | state.buffer_actions],
          %State{state | phase: :all_outputs_linked, buffer_actions: []}
        }

      :end_of_stream ->
        {
          [{:stream_format, stream_format} | state.buffer_actions] ++ [end_of_stream: pad],
          %State{state | buffer_actions: []}
        }
    end
  end

  @impl true
  def handle_buffer(:input, %Buffer{payload: bytes}, _ctx, state) do
    rest = state.parser_acc <> bytes

    {parsed, new_track_states, rest} =
      Parser.parse(rest, state.track_states)

    state = %State{
      state
      | parser_acc: rest,
        track_states: new_track_states
    }

    actions = get_packet_actions(parsed)

    case state.phase do
      :awaiting_linking ->
        {notification_actions, buffer_actions} =
          Enum.split_with(actions, fn
            {:notify_parent, {:new_track, _}} -> true
            _other -> false
          end)

        {notification_actions,
         %State{state | buffer_actions: state.buffer_actions ++ buffer_actions}}

      :all_outputs_linked ->
        {actions, state}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _context, state) do
    {[forward: :end_of_stream], %State{state | phase: :end_of_stream}}
  end

  defp get_packet_actions(packets_list) do
    Enum.flat_map(packets_list, fn packet ->
      case packet do
        %Packet{bos?: true, payload: <<"OpusHead", _rest::binary>>, track_id: track_id} ->
          [{:notify_parent, {:new_track, {track_id, :opus}}}]

        %Packet{bos?: true, payload: _not_opushead} ->
          raise "Invalid bos packet, probably unsupported codec."

        %Packet{eos?: true, payload: <<>>} ->
          []

        %Packet{payload: <<"OpusTags", _rest::binary>>} ->
          []

        %Packet{payload: data_payload, track_id: track_id} ->
          [buffer: {Pad.ref(:output, track_id), %Buffer{payload: data_payload}}]
      end
    end)
  end
end
