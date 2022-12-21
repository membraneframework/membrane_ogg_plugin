defmodule Membrane.Ogg.Demuxer do
  @moduledoc """
  A Membrane Element for demuxing an Ogg.

  For now it supports only Ogg containing a single Opus track.

  All the tracks in the Ogg must have a corresponding output pad linked (`Pad.ref(:output, track_id)`).
  """
  use Membrane.Filter
  alias Membrane.{Buffer, RemoteStream, Opus}
  require Membrane.Logger

  def_input_pad :input,
    availability: :always,
    mode: :pull,
    demand_unit: :buffers,
    accepted_format: any_of(RemoteStream)

  def_output_pad :output,
    availability: :on_request,
    mode: :pull,
    accepted_format: %RemoteStream{type: :packetized, content_format: Opus}

  @typedoc """
  Notification sent when a new track is identified in the Ogg.
  Upon receiving the notification a `Pad.ref(:output, track_id)` pad should be linked.
  """
  @type new_track_t() ::
          {:new_track, {track_id :: integer(), track_type :: atom()}}

  defmodule State do
    @type t :: %__MODULE__{
            actions_buffer: list,
            parser_acc: binary,
            phase: :all_outputs_linked | :awaiting_linking,
            continued_packets: %{},
            tracks: list
          }

    defstruct actions_buffer: [],
              parser_acc: <<>>,
              phase: :awaiting_linking,
              continued_packets: %{},
              tracks: []
  end

  @impl true
  def handle_init(_ctx, _options) do
    {[], %State{}}
  end

  @impl true
  def handle_playing(_context, state) do
    {[{:demand, :input}], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, id), _context, state) do
    stream_format = {Pad.ref(:output, id), %RemoteStream{type: :packetized, content_format: Opus}}
    state = %State{state | phase: :all_outputs_linked, tracks: state.tracks ++ [id]}

    {[stream_format: stream_format], state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: bytes}, context, state) do
    unparsed = state.parser_acc <> bytes

    {parsed, unparsed, continued_packets} =
      Membrane.Ogg.Parser.parse(unparsed, state.continued_packets)

    state = %State{state | parser_acc: unparsed, continued_packets: continued_packets}

    {actions, state} = process_packets(parsed, state)

    process_actions(actions, context, state)
  end

  @impl true
  def handle_demand(Pad.ref(:output, _id), _size, :buffers, context, state)
      when state.phase == :all_outputs_linked do
    process_actions(state.actions_buffer, context, %State{state | actions_buffer: []})
  end

  @impl true
  def handle_demand(Pad.ref(:output, _id), _size, :buffers, _context, state) do
    {:ok, state}
  end

  defp process_actions(actions, context, state) do
    demands = get_demands_from_context(context, state)

    {sent_actions, buffered_actions} = classify_actions(actions, demands, state)

    state = %State{state | actions_buffer: buffered_actions}

    actions = sent_actions ++ demand_if_not_blocked(state)

    {actions, state}
  end

  defp get_demands_from_context(context, state) do
    Enum.reduce(state.tracks, %{}, fn track, acc ->
      Map.put(acc, track, context.pads[Pad.ref(:output, track)].demand)
    end)
  end

  defp process_packets(packets_list, state) do
    Enum.reduce(packets_list, {[], state}, fn packet, {actions, state} ->
      {new_actions, state} = process_packet(packet, state)
      {actions ++ new_actions, state}
    end)
  end

  defp process_packet(packet, state) do
    cond do
      packet.bos? -> process_bos_packet(packet, state)
      packet.eos? and packet.payload == <<>> -> {[], state}
      true -> process_data_packet(packet, state)
    end
  end

  defp process_bos_packet(
         %{payload: <<"OpusHead", _rest::binary>>} = packet,
         state
       ) do
    new_track_action = {:notify_parent, {:new_track, {packet.track_id, :opus}}}

    {[new_track_action], %State{state | phase: :awaiting_linking}}
  end

  defp process_bos_packet(_other, _state) do
    raise "Invalid bos packet, probably unsupported codec."
  end

  defp process_data_packet(%{payload: <<"OpusTags", _rest::binary>>}, state) do
    {[], state}
  end

  defp process_data_packet(packet, state) do
    pad = Pad.ref(:output, packet.track_id)
    buffer_action = {:buffer, {pad, %Buffer{payload: packet.payload}}}
    {[buffer_action], state}
  end

  defp demand_if_not_blocked(state) do
    if blocked?(state), do: [], else: [demand: :input]
  end

  defp blocked?(state) do
    not Enum.empty?(state.actions_buffer) or state.phase != :all_outputs_linked
  end

  defp classify_actions(actions, demands, state) do
    if blocked?(state) do
      Enum.split_with(actions, fn
        {:notify_parent, {:new_track, _}} -> true
        _other -> false
      end)
    else
      {sent_actions, buffered_actions, _demands} =
        Enum.reduce(actions, {[], [], demands}, &classify_buffer_action/2)

      {sent_actions, buffered_actions}
    end
  end

  defp classify_buffer_action(
         {:buffer, {Pad.ref(:output, id), _buffer}} = buffer_action,
         {sent_actions, cached_actions, demands}
       ) do
    if demands[id] > 0 and Enum.empty?(cached_actions) do
      demands = %{demands | id => demands[id] - 1}
      {sent_actions ++ [buffer_action], cached_actions, demands}
    else
      {sent_actions, cached_actions ++ [buffer_action], demands}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _context, state) do
    {state.actions_buffer ++ [forward: :end_of_stream], %State{state | actions_buffer: []}}
  end
end
