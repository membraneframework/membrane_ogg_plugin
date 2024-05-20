defmodule Membrane.Ogg.Muxer do
  @moduledoc """
  A Membrane element for muxing streams into a OGG container.
  For now only supports muxing a single Opus track containing one stream (mono or stereo).

  The incoming Opus stream needs to have `:duration` field in metadata.
  """
  use Membrane.Filter
  use Numbers, overload_operators: true

  require Membrane.Logger
  alias Membrane.Element.Action
  alias Membrane.{Buffer, Opus}
  alias Membrane.Ogg.Page
  alias Membrane.Ogg.Opus.{Header, Packet}

  def_input_pad :input,
    flow_control: :auto,
    accepted_format: any_of(%Membrane.Opus{self_delimiting?: false})

  def_output_pad :output,
    flow_control: :auto,
    accepted_format: %Membrane.RemoteStream{type: :packetized, content_format: Ogg}

  @fixed_sample_rate 48_000

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            current_page: Page.t() | nil,
            total_duration: Membrane.Time.t()
          }

    @enforce_keys []
    defstruct @enforce_keys ++
                [
                  current_page: nil,
                  total_duration: 0
                ]
  end

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %State{}}
  end

  @impl true
  def handle_stream_format(:input, %Opus{channels: channels}, _ctx, state) do
    stream_format = %Membrane.RemoteStream{type: :packetized, content_format: Ogg}

    header_page =
      Page.create_first(0)
      |> Page.append_packet!(Header.create_id_header(channels))
      |> Page.finalize(false, 0)

    comment_page =
      Page.create_subsequent_to(header_page)
      |> Page.append_packet!(Header.create_comment_header())
      |> Page.finalize(false, 0)

    first_audio_data_page = Page.create_subsequent_to(comment_page)

    buffers = [
      %Buffer{payload: Page.serialize(header_page)},
      %Buffer{payload: Page.serialize(comment_page)}
    ]

    {
      [stream_format: {:output, stream_format}, buffer: {:output, buffers}],
      %{state | current_page: first_audio_data_page}
    }
  end

  @impl true
  def handle_buffer(:input, %Buffer{pts: pts} = buffer, _ctx, state) when not is_nil(pts) do
    packets_to_encapsulate =
      if pts > state.total_duration do
        Membrane.Logger.debug(
          "Stream discontiunuity of length #{Membrane.Time.as_microseconds(pts - state.total_duration, :round)}microseconds, using Packet Loss Concealment"
        )

        Packet.create_plc_packets(pts, pts - state.total_duration) ++ [buffer]
      else
        [buffer]
      end

    encapsulate_packets(packets_to_encapsulate, state)
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{current_page: current_page} = state) do
    payload =
      current_page
      |> Page.finalize(true, calculate_granule_position(state.total_duration))
      |> Page.serialize()

    {[buffer: {:output, %Buffer{payload: payload}}, end_of_stream: :output], state}
  end

  @spec calculate_granule_position(Membrane.Time.t()) :: non_neg_integer()
  def calculate_granule_position(duration) do
    (Membrane.Time.as_seconds(duration, :exact) * @fixed_sample_rate)
    |> Ratio.trunc()
  end

  @spec encapsulate_packets([Buffer.t() | Packet.plc_packet()], State.t(), [Action.t()]) ::
          {[Action.t()], State.t()}
  defp encapsulate_packets(packets, state, actions \\ [])

  defp encapsulate_packets([first_packet | rest_packets], state, actions) do
    {new_actions, state} =
      case Page.append_packet(state.current_page, first_packet.payload) do
        {:ok, page} ->
          {[], %{state | current_page: page}}

        {:error, :not_enough_space} ->
          complete_page =
            state.current_page
            |> Page.finalize(false, calculate_granule_position(first_packet.pts))

          new_page =
            Page.create_subsequent_to(complete_page)
            |> Page.append_packet!(first_packet.payload)

          {[buffer: {:output, %Buffer{payload: Page.serialize(complete_page)}}],
           %{state | current_page: new_page}}
      end

    encapsulate_packets(
      rest_packets,
      %{state | total_duration: state.total_duration + first_packet.metadata.duration},
      actions ++ new_actions
    )
  end

  defp encapsulate_packets([], state, actions) do
    {actions, state}
  end
end
