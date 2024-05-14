defmodule Membrane.OGG.Muxer do
  @moduledoc """
  A Membrane element for muxing streams into a OGG container.
  For now only supports muxing a single Opus track containing one stream (mono or stereo).
  """
  use Membrane.Filter

  def_input_pad :input,
    flow_control: :auto,
    accepted_format: any_of(%Membrane.Opus{self_delimiting?: false}),
    availability: :on_request

  def_output_pad :output,
    flow_control: :auto,
    accepted_format: %Membrane.RemoteStream{type: :packetized, content_format: OGG}

  @max_packet_size 255 * 255

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            packets: [binary()]
          }

    defstruct packets: []
  end

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    stream_format = %Membrane.RemoteStream{type: :packetized, content_format: OGG}

    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_stream_format(Pad.ref(:input, _pad_ref), _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _pad_ref), _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_buffer(Pad.ref(:input, _pad_ref), buffer, _ctx, state) do
    {[], state}
  end
end
