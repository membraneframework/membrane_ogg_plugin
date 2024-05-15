defmodule Membrane.OGG.Muxer do
  @moduledoc """
  A Membrane element for muxing streams into a OGG container.
  For now only supports muxing a single Opus track containing one stream (mono or stereo).

  The incoming Opus stream needs to have `:duration` field in metadata.
  """
  use Membrane.Filter
  require Membrane.Logger
  alias Membrane.Buffer
  alias Membrane.OGG.Muxer.Page

  def_input_pad :input,
    flow_control: :auto,
    accepted_format: any_of(%Membrane.Opus{self_delimiting?: false})

  def_output_pad :output,
    flow_control: :auto,
    accepted_format: %Membrane.RemoteStream{type: :packetized, content_format: OGG}

  @fixed_sample_rate_khz 48
  @bitstream_serial_number_range 0..0xFFFF_FFFF

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            current_page: Page.t(),
            total_duration: Membrane.Time.t()
          }

    @enforce_keys [:current_page]
    defstruct @enforce_keys ++
                [
                  total_duration: 0
                ]
  end

  @impl true
  def handle_init(_ctx, _opts) do
    new_bitstream_serial_number = Enum.random(@bitstream_serial_number_range)

    first_page = %Page{
      bos: true,
      bitstream_serial_number: new_bitstream_serial_number,
      page_sequence_number: 0,
      metadata: %{pts: 0}
    }

    {[], %State{current_page: first_page}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    stream_format = %Membrane.RemoteStream{type: :packetized, content_format: OGG}

    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_buffer(
        :input,
        %Buffer{payload: payload, pts: pts, metadata: %{duration: duration}},
        _ctx,
        %State{current_page: current_page} = state
      ) do
    if pts > state.total_duration do
      Membrane.Logger.debug("dupa: #{pts - state.total_duration}")
    end

    {actions, state} =
      case Page.add_packet(current_page, payload) do
        {:ok, page} ->
          {[], %{state | current_page: page}}

        {:error, :not_enough_space} ->
          page_granule_position =
            Membrane.Time.as_milliseconds(pts, :round) * @fixed_sample_rate_khz

          serialized_page = finalize_page(current_page, false, page_granule_position)

          new_empty_page = %Page{
            bos: false,
            bitstream_serial_number: current_page.bitstream_serial_number,
            page_sequence_number: current_page.page_sequence_number + 1,
            metadata: %{pts: pts}
          }

          new_page =
            case Page.add_packet(new_empty_page, payload) do
              {:ok, page} -> page
              {:error, :not_enough_space} -> raise "Packet too big"
            end

          {[buffer: {:output, %Buffer{payload: serialized_page}}],
           %{state | current_page: new_page}}
      end

    {actions, %{state | total_duration: state.total_duration + duration}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{current_page: current_page} = state) do
    payload =
      finalize_page(current_page, false, state.total_duration * @fixed_sample_rate_khz * 1000)

    {[buffer: {:output, %Buffer{payload: payload}}, end_of_stream: :output], state}
  end

  @spec finalize_page(Page.t(), boolean(), integer()) :: binary()
  def finalize_page(page, eos, granule_position) do
    %{page | eos: eos, granule_position: granule_position}
    |> Page.serialize()
  end
end
