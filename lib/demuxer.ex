defmodule Membrane.Ogg.Demuxer do
  @moduledoc """
  A Membrane Element for demuxing an Ogg.

  For now it supports only Ogg containing a single Opus track.

  All the tracks in the Ogg must have a corresponding output pad linked (`Pad.ref(:output, track_id)`).

  The demuxer adds metadata to the buffers in form of `%{ogg: %{page_pts: Membrane.Time.t() | nil}}`.
  The value is set only for the first completed packet of each OGG page and is calculated
  based on the page's granule position (see [RFC 7845, sec. 4](https://www.rfc-editor.org/rfc/rfc7845.txt)).
  For non-first packets it's set to `nil`.
  """
  use Membrane.Filter
  require Membrane.Logger
  alias Membrane.Ogg.Parser.Packet
  alias Membrane.{Buffer, Opus, RemoteStream}
  alias Membrane.Ogg.Parser

  def_input_pad :input,
    flow_control: :auto,
    accepted_format: any_of(RemoteStream)

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
            actions_buffer: [Membrane.Element.Action.t()],
            parser_acc: binary(),
            phase: :all_outputs_linked | :awaiting_linking,
            track_states: Parser.track_states()
          }

    defstruct actions_buffer: [],
              parser_acc: <<>>,
              phase: :awaiting_linking,
              track_states: %{}
  end

  @impl true
  def handle_init(_ctx, _options) do
    {[], %State{}}
  end

  # @impl true
  # def handle_playing(_context, state) do
  #   {[{:demand, :input}], state}
  # end

  @impl true
  def handle_pad_added(Pad.ref(:output, id), _context, state) do
    stream_format = {Pad.ref(:output, id), %RemoteStream{type: :packetized, content_format: Opus}}
    state = %State{state | phase: :all_outputs_linked}

    {[stream_format: stream_format] ++ state.actions_buffer, state}
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

    {notification_actions, buffer_actions} = process_packets(parsed)

    case state.phase do
      :awaiting_linking ->
        {notification_actions,
         %State{state | actions_buffer: state.actions_buffer ++ buffer_actions}}

      :all_outputs_linked ->
        {notification_actions ++ buffer_actions, state}
    end

    # process_actions(actions, context, state)
  end

  # @impl true
  # def handle_demand(Pad.ref(:output, _id), _size, :buffers, context, state)
  #     when state.phase == :all_outputs_linked do
  #   process_actions(state.actions_buffer, context, %State{state | actions_buffer: []})
  # end

  # @impl true
  # def handle_demand(Pad.ref(:output, _id), _size, :buffers, _context, state) do
  #   {:ok, state}
  # end

  defp process_actions(actions, context, state) do
    demands = get_demands_from_context(context, state)

    {sent_actions, buffered_actions} = classify_actions(actions, demands, state)

    state = %State{state | actions_buffer: buffered_actions}

    actions = sent_actions ++ demand_if_not_blocked(state)

    {actions, state}
  end

  defp get_demands_from_context(context, state) do
    Enum.reduce(state.track_states, %{}, fn {track, _track_state}, acc ->
      case context.pads[Pad.ref(:output, track)] do
        nil ->
          acc

        %{demand: demand} ->
          Map.put(acc, track, demand)
      end
    end)
  end

  defp process_packets(packets_list) do
    Enum.reduce(packets_list, [], fn packet, actions ->
      new_actions = process_packet(packet)
      actions ++ new_actions
    end)
    |> Enum.split_with(fn
      {:notify_parent, {:new_track, _}} -> true
      _other -> false
    end)
  end

  defp process_packet(packet) do
    case packet do
      %Packet{bos?: true} ->
        process_bos_packet(packet)

      %Packet{eos?: true, payload: <<>>} ->
        []

      data_packet ->
        process_data_packet(data_packet)
    end
  end

  defp process_bos_packet(%{payload: <<"OpusHead", _rest::binary>>} = packet, state) do
    new_track_action = {:notify_parent, {:new_track, {packet.track_id, :opus}}}

    [new_track_action]
  end

  defp process_bos_packet(_other) do
    raise "Invalid bos packet, probably unsupported codec."
  end

  defp process_data_packet(%{payload: <<"OpusTags", _rest::binary>>}) do
    []
  end

  defp process_data_packet(packet) do
    pad = Pad.ref(:output, packet.track_id)

    buffer_action =
      {:buffer,
       {pad, %Buffer{payload: packet.payload, metadata: %{ogg: %{page_pts: packet.page_pts}}}}}

    [buffer_action]
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
    {[forward: :end_of_stream], %State{state | actions_buffer: []}}
  end
end
