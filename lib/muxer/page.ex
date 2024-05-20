defmodule Membrane.OGG.Muxer.Page do
  @moduledoc false

  import Bitwise

  alias Membrane.OGG.Muxer.Page

  @type t :: %Page{
          continued: boolean(),
          bos: boolean(),
          eos: boolean() | :tbd,
          granule_position: integer() | :tbd,
          bitstream_serial_number: non_neg_integer(),
          page_sequence_number: non_neg_integer(),
          number_page_segments: non_neg_integer(),
          segment_table: [0..255],
          data: binary()
        }

  @enforce_keys [:bos, :bitstream_serial_number, :page_sequence_number]
  defstruct @enforce_keys ++
              [
                continued: false,
                eos: :tbd,
                granule_position: :tbd,
                number_page_segments: 0,
                segment_table: [],
                data: <<>>
              ]

  @capture_pattern "OggS"
  @version 0
  @crc_params %{
    extend: :crc_32,
    poly: 0x04C11DB7,
    init: 0x0,
    xorout: 0x0,
    refin: false,
    refout: false
  }
  @spec create_first(non_neg_integer()) :: Page.t()
  def create_first(bitstream_serial_number) do
    %Page{
      bos: true,
      bitstream_serial_number: bitstream_serial_number,
      page_sequence_number: 0
    }
  end

  @spec create_subsequent(Page.t()) :: Page.t()
  def create_subsequent(page) do
    %Page{
      bos: false,
      bitstream_serial_number: page.bitstream_serial_number,
      page_sequence_number: page.page_sequence_number + 1
    }
  end

  @spec append_packet(Page.t(), binary()) :: {:ok, Page.t()} | {:error, :not_enough_space}
  def append_packet(page, packet) do
    %{number_page_segments: number_page_segments, segment_table: segment_table, data: data} = page

    packet_segments = create_segment_table(packet)

    if length(segment_table) + length(packet_segments) > 255 do
      {:error, :not_enough_space}
    else
      updated_page =
        %{
          page
          | number_page_segments: number_page_segments + length(packet_segments),
            segment_table: segment_table ++ packet_segments,
            data: data <> packet
        }

      {:ok, updated_page}
    end
  end

  @spec append_packet!(Page.t(), binary()) :: Page.t()
  def append_packet!(page, packet) do
    case append_packet(page, packet) do
      {:ok, page} -> page
      {:error, reason} -> raise "Error appending packet to the page, reason: #{inspect(reason)}"
    end
  end

  @spec finalize(Page.t(), boolean(), integer()) :: Page.t()
  def finalize(page, eos, granule_position) do
    %Page{page | eos: eos, granule_position: granule_position}
  end

  @spec serialize(Page.t()) :: binary()
  def serialize(page) do
    %{
      granule_position: granule_position,
      bitstream_serial_number: bitstream_serial_number,
      page_sequence_number: page_sequence_number,
      number_page_segments: number_page_segments,
      segment_table: segment_table,
      data: data
    } = page

    if page.eos == :tbd or page.granule_position == :tbd,
      do: raise("eos or granule position not set, Page not finalized (run finalize/2)")

    before_crc =
      <<@capture_pattern, @version, serialize_type(page), granule_position::little-signed-64,
        bitstream_serial_number::little-32, page_sequence_number::little-32>>

    after_crc = <<number_page_segments>> <> :binary.list_to_bin(segment_table) <> data

    crc = CRC.calculate(<<before_crc::binary, 0::32, after_crc::binary>>, @crc_params)

    <<before_crc::binary, crc::little-32, after_crc::binary>>
  end

  @spec create_segment_table(binary()) :: [0..255]
  defp create_segment_table(packet) do
    case packet do
      <<_segment::binary-255, rest::binary>> ->
        [255 | create_segment_table(rest)]

      <<shorter_segment::binary>> ->
        [byte_size(shorter_segment)]

      <<>> ->
        [0]
    end
  end

  @spec serialize_type(Page.t()) :: 0..7
  defp serialize_type(page) do
    continued = if page.continued, do: 0x01, else: 0
    bos = if page.bos, do: 0x02, else: 0
    eos = if page.eos, do: 0x04, else: 0
    continued ||| bos ||| eos
  end
end
