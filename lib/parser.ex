defmodule Membrane.Ogg.Parser do
  import Bitwise

  defmodule Packet do
    defstruct payload: <<>>,
              track_id: 0,
              bos?: false,
              eos?: false
  end

  @type continued_packets_t :: %{integer => binary}

  @spec parse(binary, %{}) ::
          {parsed :: list(Packet), unparsed :: binary, continued_packets :: continued_packets_t}
  def parse(data, continued_packets) do
    do_parse([], data, continued_packets)
  end

  defp do_parse(acc, data, continued_packets) do
    case parse_page(data, continued_packets) do
      {:error, :need_more_bytes} ->
        {acc, data, continued_packets}

      {:error, :invalid_crc} ->
        raise "Corrupted stream: invalid crc"

      {:error, :invalid_header} ->
        raise "Corrupted stream: invalid page header"

      {:ok, packets, continued_packets, unparsed} ->
        do_parse(acc ++ packets, unparsed, continued_packets)
    end
  end

  defp parse_page(initial_bytes, continued_packets) do
    with {:ok, data, header_type, bitstream_serial_number, number_of_page_segments} <-
           parse_header(initial_bytes),
         {:ok, segment_table, data} <- parse_segment_table(data, number_of_page_segments),
         :ok <- verify_length_and_crc(initial_bytes, segment_table) do
      {packets, page_continued_packet, rest} = parse_segments(data, segment_table)

      {packets, continued_packets} =
        prepend_continued_packet(
          continued_packets,
          bitstream_serial_number,
          packets,
          page_continued_packet
        )

      packets =
        Enum.map(packets, fn packet ->
          %Packet{
            payload: packet,
            track_id: bitstream_serial_number,
            bos?: (header_type &&& 0x2) > 0,
            eos?: (header_type &&& 0x4) > 0
          }
        end)

      {:ok, packets, continued_packets, rest}
    end
  end

  defp parse_header(
         <<"OggS", 0, header_type, _granule_position::64,
           bitstream_serial_number::little-unsigned-size(32), _page_sequence_number::32, _crc::32,
           number_of_page_segments, rest::binary>>
       ) do
    {:ok, rest, header_type, bitstream_serial_number, number_of_page_segments}
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
      <<before_crc::binary-size(22), crc::little-unsigned-size(32),
        after_crc::binary-size(1 + segments_count + content_length), _rest::binary>> = data

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

    if(List.last(segment_table) == 255) do
      {List.delete_at(packets, -1), List.last(packets), data}
    else
      {packets, nil, data}
    end
  end

  defp prepend_continued_packet(
         continued_packets,
         bitstream_serial_number,
         packets,
         page_continued_packet
       ) do
    {packets, continued_packets, page_continued_packet} =
      if Map.has_key?(continued_packets, bitstream_serial_number) do
        # a special case when there is just one unfinished packet in the page
        if Enum.empty?(packets) do
          page_continued_packet =
            continued_packets[bitstream_serial_number] <> page_continued_packet

          {packets, continued_packets, page_continued_packet}
        else
          [first_packet | rest_of_packets] = packets

          packets = [
            continued_packets[bitstream_serial_number] <> first_packet | rest_of_packets
          ]

          continued_packets = Map.delete(continued_packets, bitstream_serial_number)

          {packets, continued_packets, page_continued_packet}
        end
      else
        {packets, continued_packets, page_continued_packet}
      end

    if page_continued_packet != nil do
      continued_packets =
        Map.put(continued_packets, bitstream_serial_number, page_continued_packet)

      {packets, continued_packets}
    else
      {packets, continued_packets}
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
