defmodule Membrane.Ogg.Muxer do
  @moduledoc """
  A Membrane element for muxing streams into a OGG container.
  For now only supports muxing a single Opus track containing one stream (mono or stereo).

  The incoming Opus stream needs to have `:duration` field in metadata.
  """
  use Membrane.Filter
  use Numbers, overload_operators: true

  require Membrane.Logger
  alias Membrane.{Buffer, Ogg}
  alias Membrane.Ogg.Page

  def_input_pad :input,
    accepted_format: %Membrane.Opus{self_delimiting?: false}

  def_output_pad :output,
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
  def handle_stream_format(:input, %Membrane.Opus{channels: channels}, _ctx, state) do
    stream_format = %Membrane.RemoteStream{type: :packetized, content_format: Ogg}

    header_page =
      Page.create_first(0)
      |> Page.append_packet!(Ogg.Opus.create_id_header(channels))
      |> Page.finalize(0)

    comment_page =
      Page.create_subsequent(header_page)
      |> Page.append_packet!(Ogg.Opus.create_comment_header())
      |> Page.finalize(0)

    first_audio_data_page = Page.create_subsequent(comment_page)

    buffers = [
      %Buffer{payload: Page.serialize(header_page)},
      %Buffer{payload: Page.serialize(comment_page)}
    ]

    {
      [stream_format: {:output, stream_format}, buffer: {:output, buffers}],
      %State{state | current_page: first_audio_data_page}
    }
  end

  @impl true
  def handle_buffer(
        :input,
        %Buffer{pts: pts, metadata: %{duration: _duration}} = buffer,
        _ctx,
        state
      )
      when not is_nil(pts) do
    packets_to_encapsulate =
      if pts > state.total_duration do
        Membrane.Logger.debug(
          "Stream discontiunuity of length #{Membrane.Time.as_milliseconds(pts - state.total_duration, :exact) |> Ratio.to_float()}ms, using Packet Loss Concealment"
        )

        Membrane.Ogg.Opus.create_plc_packets(pts, pts - state.total_duration) ++ [buffer]
      else
        [buffer]
      end

    {buffers, state} = encapsulate_packets(packets_to_encapsulate, state)

    {[buffer: {:output, buffers}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{current_page: current_page} = state) do
    payload =
      current_page
      |> Page.finalize(calculate_granule_position(state.total_duration), true)
      |> Page.serialize()

    {[buffer: {:output, %Buffer{payload: payload}}, end_of_stream: :output], state}
  end

  @spec calculate_granule_position(Membrane.Time.t()) :: non_neg_integer()
  defp calculate_granule_position(duration) do
    (Membrane.Time.as_seconds(duration, :exact) * @fixed_sample_rate)
    |> Ratio.trunc()
  end

  @spec encapsulate_packets([Buffer.t() | Membrane.Ogg.Opus.plc_packet()], State.t(), [Buffer.t()]) ::
          {pages :: [Buffer.t()], state :: State.t()}
  defp encapsulate_packets(packets, state, page_buffers \\ [])

  defp encapsulate_packets([first_packet | rest_packets], state, page_buffers) do
    {new_page_buffers, state} =
      case Page.append_packet(state.current_page, first_packet.payload) do
        {:ok, page} ->
          {[], %State{state | current_page: page}}

        {:error, :not_enough_space} ->
          complete_page =
            state.current_page
            |> Page.finalize(calculate_granule_position(first_packet.pts))

          new_page =
            Page.create_subsequent(complete_page)
            |> Page.append_packet!(first_packet.payload)

          {[%Buffer{payload: Page.serialize(complete_page)}],
           %State{state | current_page: new_page}}
      end

    encapsulate_packets(
      rest_packets,
      %{state | total_duration: state.total_duration + first_packet.metadata.duration},
      page_buffers ++ new_page_buffers
    )
  end

  defp encapsulate_packets([], state, page_buffers) do
    {page_buffers, state}
  end
end
