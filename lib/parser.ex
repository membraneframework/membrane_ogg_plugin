defmodule Membrane.Ogg.Parser do
  @moduledoc false

  import Bitwise

  defmodule Packet do
    @moduledoc false

    @type t() :: %__MODULE__{
            payload: binary(),
            bos?: boolean(),
            eos?: boolean()
          }

    defstruct payload: <<>>,
              bos?: false,
              eos?: false
  end

  @spec parse(binary(), binary() | nil) ::
          {parsed :: [Packet.t()], new_continued_packet :: binary(), rest :: binary()}
  def parse(data, continued_packet) do
    do_parse([], data, continued_packet)
  end

  defp do_parse(acc, data, continued_packet) do
    case parse_page(data, continued_packet) do
      {:error, :need_more_bytes} ->
        {acc, continued_packet, data}

      {:error, :invalid_crc} ->
        raise "Corrupted stream: invalid crc"

      {:error, :invalid_header} ->
        raise "Corrupted stream: invalid page header"

      {:ok, packets, incomplete_packet, rest} ->
        do_parse(acc ++ packets, rest, incomplete_packet)
    end
  end

  defp parse_page(initial_bytes, continued_packet) do
    with {:ok, data, header_type, number_of_page_segments} <- parse_header(initial_bytes),
         {:ok, segment_table, data} <- parse_segment_table(data, number_of_page_segments),
         :ok <- verify_length_and_crc(initial_bytes, segment_table) do
      {packets, incomplete_packet, rest} = parse_segments(data, segment_table)

      {packets, incomplete_packet} =
        prepend_continued_packet(
          continued_packet,
          packets,
          incomplete_packet
        )

      packets =
        Enum.map(packets, fn packet ->
          %Packet{
            payload: packet,
            bos?: (header_type &&& 0x2) > 0,
            eos?: (header_type &&& 0x4) > 0
          }
        end)

      {:ok, packets, incomplete_packet, rest}
    end
  end

  defp parse_header(
         <<"OggS", 0, header_type, _granule_position::little-signed-64,
           _bitstream_serial_number::little-unsigned-32, _page_sequence_number::32, _crc::32,
           number_of_page_segments, rest::binary>>
       ) do
    {:ok, rest, header_type, number_of_page_segments}
  end

  defp parse_header(<<_header_data::binary-size(27), _rest::binary>>) do
    {:error, :invalid_header}
  end

  defp parse_header(_too_short) do
    {:error, :need_more_bytes}
  end

  defp parse_segment_table(data, page_segments_count) do
    case data do
      <<segment_table::binary-size(page_segments_count), data::binary>> ->
        {:ok, :binary.bin_to_list(segment_table), data}

      _other ->
        {:error, :need_more_bytes}
    end
  end

  defp verify_length_and_crc(data, segment_table) do
    segments_count = Enum.count(segment_table)
    content_length = Enum.sum(segment_table)

    # 27 is the number of bytes in ogg page header before segments table, see Ogg RFC: https://www.rfc-editor.org/rfc/rfc3533#page-9
    if 27 + segments_count + content_length > byte_size(data) do
      {:error, :need_more_bytes}
    else
      after_crc_size = 1 + segments_count + content_length

      <<before_crc::binary-size(22), crc::little-unsigned-size(32),
        after_crc::binary-size(after_crc_size), _rest::binary>> = data

      crc_payload = <<before_crc::binary, 0::size(32), after_crc::binary>>

      calculated_crc =
        CRC.crc(
          %{
            extend: :crc_32,
            init: 0x0,
            poly: 0x04C11DB7,
            xorout: 0x0,
            refin: false,
            refout: false
          },
          crc_payload
        )

      if calculated_crc == crc do
        :ok
      else
        {:error, :invalid_crc}
      end
    end
  end

  defp parse_segments(data, segment_table) do
    chunk_fun = fn element, acc ->
      if element == 255 do
        {:cont, [element | acc]}
      else
        {:cont, Enum.reverse([element | acc]), []}
      end
    end

    after_chunk = fn
      [] -> {:cont, []}
      acc -> {:cont, acc, []}
    end

    packets_segments = Enum.chunk_while(segment_table, [], chunk_fun, after_chunk)
    packets_lengths = Enum.map(packets_segments, &Enum.sum/1)

    {packets, data} = split_packets(data, packets_lengths)

    if List.last(segment_table) == 255 do
      {List.delete_at(packets, -1), List.last(packets), data}
    else
      {packets, nil, data}
    end
  end

  defp prepend_continued_packet(continued_packet, packets, incomplete_packet) do
    cond do
      continued_packet == nil ->
        {packets, incomplete_packet}

      Enum.empty?(packets) ->
        {packets, continued_packet <> incomplete_packet}

      true ->
        [first_packet | rest_packets] = packets
        {[continued_packet <> first_packet | rest_packets], incomplete_packet}
    end
  end

  defp split_packets(data, []) do
    {[], data}
  end

  defp split_packets(data, [count | rem_counts]) do
    <<packet::binary-size(count), rem_data::binary>> = data
    {packets, rem_data} = split_packets(rem_data, rem_counts)
    {[packet | packets], rem_data}
  end
end
