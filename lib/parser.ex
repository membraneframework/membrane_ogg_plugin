defmodule Membrane.Ogg.Parser do
  import Bitwise

  @type packet :: %{payload: binary, track_id: integer, bos?: boolean, eos?: boolean}

  @spec parse(binary, continued_packets :: %{}) ::
          {parsed :: list(packet), unparsed :: binary, continued_packets :: %{}}
  def parse(data, continued_packets) do
    do_parse([], data, continued_packets)
  end

  @spec do_parse(acc :: list(packet), data :: binary, continued_packets :: %{}) ::
          {parsed :: list(packet), data :: binary, continued_packets :: %{}}
  defp do_parse(acc, data, continued_packets) do
    case maybe_parse_page(data, continued_packets) do
      {:error, :need_more_bytes} ->
        {acc, data, continued_packets}

      {:ok, unparsed, packets, continued_packets} ->
        do_parse(acc ++ packets, unparsed, continued_packets)
    end
  end

  @spec maybe_parse_page(page :: binary, continued_packets :: %{}) ::
          {:ok, data :: binary, packets :: list(packet), continued_packets :: %{}}
          | {:error, :need_more_bytes}
  defp maybe_parse_page(initial_bytes, continued_packets) do
    with {:ok, data, header_type, bitstream_serial_number, number_of_page_segments} <-
           parse_header(initial_bytes),
         {:ok, data, segment_table} <- parse_segment_table(data, number_of_page_segments),
         :ok <- verify_length_and_crc(initial_bytes, segment_table) do
      {data, packets, page_continued_packet} = parse_segments(data, segment_table)

      {packets, continued_packets, page_continued_packet} =
        prepend_continued_packet(
          continued_packets,
          bitstream_serial_number,
          packets,
          page_continued_packet
        )

      packets =
        Enum.map(packets, fn packet ->
          %{
            payload: packet,
            track_id: bitstream_serial_number,
            bos?: (header_type &&& 0x2) > 0,
            eos?: (header_type &&& 0x4) > 0
          }
        end)

      continued_packets =
        if page_continued_packet == nil do
          continued_packets
        else
          Map.put(continued_packets, bitstream_serial_number, page_continued_packet)
        end

      {:ok, data, packets, continued_packets}
    end
  end

  defp verify_length_and_crc(data, segment_table) do
    segments_count = Enum.count(segment_table)
    content_length = Enum.sum(segment_table)

    if 22 + 4 + 1 + segments_count + content_length > byte_size(data) do
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
        raise "Corrupted stream: invalid crc"
      end
    end
  end

  @spec prepend_continued_packet(
          continued_packets :: %{},
          bitstream_serial_number :: integer,
          packets :: list(binary),
          page_continued_packet :: binary | nil
        ) ::
          {packets :: list(binary), continued_packets :: %{},
           page_continued_packet :: binary | nil}
  defp prepend_continued_packet(
         continued_packets,
         bitstream_serial_number,
         packets,
         page_continued_packet
       ) do
    if Map.has_key?(continued_packets, bitstream_serial_number) do
      # a special case when there is just one unfinished packet in the page
      if Enum.empty?(packets) do
        page_continued_packet =
          continued_packets[bitstream_serial_number] <> page_continued_packet

        continued_packets =
          Map.put(continued_packets, bitstream_serial_number, page_continued_packet)

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
  end

  @spec parse_header(data :: binary) ::
          {:ok, data :: binary, header_type :: integer, bitstream_serial_number :: integer,
           number_of_page_segments :: integer}
          | {:error, :need_more_bytes}
  defp parse_header(
         <<"OggS", 0, header_type::unsigned-size(8), _granule_position::unsigned-size(64),
           bitstream_serial_number::little-unsigned-size(32),
           _page_sequence_number::unsigned-size(32), _crc::unsigned-size(32),
           number_of_page_segments::unsigned-size(8), rest::binary>>
       ) do
    {:ok, rest, header_type, bitstream_serial_number, number_of_page_segments}
  end

  defp parse_header(<<_header_data::binary-size(27), _rest::binary>>) do
    raise "Corrupted stream: invalid page header"
  end

  defp parse_header(_too_short) do
    {:error, :need_more_bytes}
  end

  @spec parse_segment_table(data :: binary, page_segments_count :: integer) ::
          {:ok, data :: binary, list(integer)} | {:error, :need_more_bytes}
  defp parse_segment_table(data, page_segments_count) do
    if byte_size(data) < page_segments_count do
      {:error, :need_more_bytes}
    else
      <<segment_table::binary-size(page_segments_count), data::binary>> = data
      {:ok, data, :binary.bin_to_list(segment_table)}
    end
  end

  @spec parse_segments(data :: binary, segment_table :: list(integer)) ::
          {binary, list(binary), binary | nil}
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

    {data, packets} = split_packets(data, packets_lengths)

    if(List.last(segment_table) == 255) do
      {data, Enum.drop(packets, 1), List.last(packets)}
    else
      {data, packets, nil}
    end
  end

  @spec split_packets(data :: binary, counts :: list(integer)) :: {binary, list(binary)}
  defp split_packets(data, []) do
    {data, []}
  end

  defp split_packets(data, [count | rest_counts]) do
    <<packet::binary-size(count), data::binary>> = data
    {data, packets} = split_packets(data, rest_counts)
    {data, [packet | packets]}
  end
end
