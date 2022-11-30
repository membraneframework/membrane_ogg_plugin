defmodule Membrane.Ogg.Demuxer do
  use Membrane.Filter
  alias Membrane.{Buffer, RemoteStream, Opus}

  def_input_pad :input,
    availability: :always,
    mode: :pull,
    demand_unit: :buffers,
    accepted_format: any_of(RemoteStream)

  def_output_pad :output,
    availability: :on_request,
    mode: :pull,
    accepted_format: %RemoteStream{type: :packetized, content_format: Opus}

  defmodule State do
    @type t :: %__MODULE__{
            actions_buffer: list,
            parser_acc: binary,
            phase: :all_outputs_linked | :awaiting_linking,
            continued_packets: %{}
          }

    defstruct actions_buffer: [],
              parser_acc: <<>>,
              phase: :awaiting_linking,
              continued_packets: %{}
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
    {[
       stream_format:
         {Pad.ref(:output, id), %RemoteStream{type: :packetized, content_format: Opus}}
     ], %State{state | phase: :all_outputs_linked}}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: bytes}, context, state) do
    unparsed = state.parser_acc <> bytes

    {parsed, unparsed, continued_packets} =
      Membrane.Ogg.Parser.parse(unparsed, state.continued_packets)

    state = %State{state | parser_acc: unparsed}
    state = %State{state | continued_packets: continued_packets}

    {actions, state} = process_packets({[], context, state}, parsed)

    demand_if_not_blocked({actions, state})
  end

  @impl true
  def handle_demand(Pad.ref(:output, _id), _size, :buffers, context, state)
      when state.phase == :all_outputs_linked do
    {[], state}
    |> reclassify_buffer_actions(context)
    |> demand_if_not_blocked()
  end

  @impl true
  def handle_demand(Pad.ref(:output, _id), _size, :buffers, _context, state) do
    {:ok, state}
  end

  defp process_packets({actions, context, state}, packets_list) do
    {actions, _context, state} =
      Enum.reduce(packets_list, {actions, context, state}, &process_packet/2)

    {actions, state}
  end

  defp process_packet(packet, {actions, context, state}) do
    cond do
      packet.bos? -> process_bos_packet(packet, {actions, context, state})
      packet.eos? -> {actions, context, state}
      true -> process_data_packet(packet, {actions, context, state})
    end
  end

  defp process_bos_packet(packet, {actions, context, state}) do
    case packet.payload do
      <<"OpusHead", _rest::binary>> ->
        new_track_action = {:notify_parent, {:new_track, {packet.track_id, :opus}}}
        {actions ++ [new_track_action], context, %State{state | phase: :awaiting_linking}}
    end
  end

  defp process_data_packet(packet, {actions, context, state}) do
    case packet.payload do
      <<"OpusTags", _rest::binary>> ->
        {actions, context, state}

      payload ->
        buffer_action =
          {:buffer,
           {Pad.ref(:output, packet.track_id),
            %Buffer{
              payload: payload
            }}}

        classify_buffer_action(buffer_action, {actions, context, state})
    end
  end

  defp demand_if_not_blocked({actions, state}) do
    if blocked?(state) do
      {actions, state}
    else
      actions = actions ++ [{:demand, :input}]
      {actions, state}
    end
  end

  defp blocked?(state) do
    not Enum.empty?(state.actions_buffer) or state.phase != :all_outputs_linked
  end

  defp classify_buffer_action(
         {:buffer, {Pad.ref(:output, id), _buffer}} = buffer_action,
         {actions, context, state}
       ) do
    if not blocked?(state) and context.pads[Pad.ref(:output, id)].demand > 0 do
      context = update_in(context.pads[Pad.ref(:output, id)].demand, &(&1 - 1))
      {actions ++ [buffer_action], context, state}
    else
      {actions, context, %State{state | actions_buffer: state.actions_buffer ++ [buffer_action]}}
    end
  end

  defp reclassify_buffer_actions({actions, state}, context) do
    {actions, _context, state} =
      Enum.reduce(state.actions_buffer, {actions, context, state}, &classify_buffer_action/2)

    {actions, state}
  end

  @impl true
  def handle_end_of_stream(:input, context, state) do
    end_actions =
      context.pads
      |> Enum.filter(fn {_pad_ref, pad_data} -> pad_data.direction == :output end)
      |> Enum.map(fn {pad_ref, _pad_data} -> {:end_of_stream, pad_ref} end)

    {state.actions_buffer ++ end_actions, %State{state | actions_buffer: []}}
  end
end
