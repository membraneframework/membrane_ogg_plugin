defmodule Membrane.OGG.Muxer do
  @moduledoc """
  A Membrane element for muxing streams into a OGG container.
  For now only supports muxing a single Opus track containing one stream (mono or stereo).

  The incoming Opus stream needs to have `:duration` field in metadata.
  """
  use Membrane.Filter
  use Numbers, overload_operators: true

  require Membrane.Logger
  alias Membrane.{Buffer, Opus}
  alias Membrane.OGG.Muxer.Page
  alias Membrane.OGG.Muxer.Page.Header

  def_input_pad :input,
    flow_control: :auto,
    accepted_format: any_of(%Membrane.Opus{self_delimiting?: false})

  def_output_pad :output,
    flow_control: :auto,
    accepted_format: %Membrane.RemoteStream{type: :packetized, content_format: OGG}

  @fixed_sample_rate 48_000
  @bitstream_serial_number_range 0..0xFFFF_FFFF

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
    stream_format = %Membrane.RemoteStream{type: :packetized, content_format: OGG}

    header_page =
      Enum.random(@bitstream_serial_number_range)
      |> Page.create_first()
      |> Page.append_packet!(Header.create_id_header(channels))
      |> Page.finalize(false, 0)

    comment_page =
      header_page
      |> Page.create_subsequent()
      |> Page.append_packet!(Header.create_comment_header())
      |> Page.finalize(false, 0)

    first_audio_data_page = Page.create_subsequent(comment_page)

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
  def handle_buffer(
        :input,
        %Buffer{payload: packet, pts: pts, metadata: %{duration: duration}},
        _ctx,
        %State{current_page: current_page} = state
      ) do
    if pts > state.total_duration do
      Membrane.Logger.debug("#{pts - state.total_duration}")
    end

    {actions, state} =
      case Page.append_packet(current_page, packet) do
        {:ok, page} ->
          {[], %{state | current_page: page}}

        {:error, :not_enough_space} ->
          complete_page =
            current_page
            |> Page.finalize(false, calculate_granule_position(pts))

          new_page =
            complete_page
            |> Page.create_subsequent()
            |> Page.append_packet!(packet)

          {[buffer: {:output, %Buffer{payload: Page.serialize(complete_page)}}],
           %{state | current_page: new_page}}
      end

    {actions, %{state | total_duration: state.total_duration + duration}}
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
end
