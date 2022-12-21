defmodule ParserTest do
  use ExUnit.Case, async: true

  import Membrane.Ogg.Parser
  alias Membrane.Ogg.Parser.Packet

  defp create_page(segments) do
    segment_table = Enum.map(segments, fn seg -> <<seg>> end) |> Enum.join()
    content = Enum.map(segments, fn seg -> segment(seg) end) |> Enum.join()
    before_crc = <<"OggS", 0, 0, 0::size(8 * 8), 0::size(4 * 8), 0::size(4 * 8)>>
    after_crc = <<Enum.count(segments)>> <> segment_table <> content
    crc_payload = before_crc <> <<0::size(32)>> <> after_crc

    crc =
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

    before_crc <> <<crc::little-unsigned-size(32)>> <> after_crc
  end

  defp create_page_with_invalid_crc(segments) do
    <<before_crc::binary-size(22), _crc::binary-size(4), after_crc::binary>> =
      create_page(segments)

    before_crc <> <<0::size(32)>> <> after_crc
  end

  defp create_page_with_invalid_header(segments) do
    <<"OggS", rest::binary>> = create_page(segments)
    <<"RanD">> <> rest
  end

  defp segment(len) do
    <<len::size(len * 8)>>
  end

  test "Parses a simple page with a single segment" do
    page = create_page([5])
    {parsed, unparsed, continued_packets} = parse(page, %{})
    assert parsed == [%Packet{payload: segment(5), track_id: 0, bos?: false, eos?: false}]
    assert unparsed == <<>>
    assert continued_packets == %{}
  end

  test "Parses a simple page with multiple segments" do
    page = create_page([255, 7])

    {parsed, unparsed, continued_packets} = parse(page, %{})

    assert parsed == [
             %Packet{
               payload: segment(255) <> segment(7),
               track_id: 0,
               bos?: false,
               eos?: false
             }
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}
  end

  test "Doesn't parse if input is too short" do
    page = create_page([255, 7, 3])

    slices = Enum.map(0..(byte_size(page) - 1), fn x -> String.slice(page, 0, x) end)
    assert Enum.all?(slices, fn x -> parse(x, %{}) == {[], x, %{}} end) == true
  end

  test "Parses multiple pages" do
    page1 = create_page([5])
    page2 = create_page([3])
    page3 = create_page([255, 7])

    {parsed, unparsed, continued_packets} = parse(page1 <> page2, %{})

    assert parsed == [
             %Packet{payload: segment(5), track_id: 0, bos?: false, eos?: false},
             %Packet{payload: segment(3), track_id: 0, bos?: false, eos?: false}
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}

    {parsed, unparsed, continued_packets} = parse(page1 <> page2 <> page3, %{})

    assert parsed == [
             %Packet{payload: segment(5), track_id: 0, bos?: false, eos?: false},
             %Packet{payload: segment(3), track_id: 0, bos?: false, eos?: false},
             %Packet{
               payload: segment(255) <> segment(7),
               track_id: 0,
               bos?: false,
               eos?: false
             }
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}
  end

  test "Parses a page with multiple packets" do
    page = create_page([255, 7, 10])

    {parsed, unparsed, continued_packets} = parse(page, %{})

    assert parsed == [
             %Packet{
               payload: segment(255) <> segment(7),
               track_id: 0,
               bos?: false,
               eos?: false
             },
             %Packet{payload: segment(10), track_id: 0, bos?: false, eos?: false}
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}
  end

  test "Parses a packet spanning through multiple pages" do
    page1 = create_page([255, 255])
    page2 = create_page([3])

    {parsed, unparsed, continued_packets} = parse(page1 <> page2, %{})

    assert parsed == [
             %Packet{
               payload: segment(255) <> segment(255) <> segment(3),
               track_id: 0,
               bos?: false,
               eos?: false
             }
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}

    {parsed, unparsed, continued_packets} = parse(page1, %{})

    assert parsed == []
    assert unparsed == <<>>
    assert continued_packets == %{0 => segment(255) <> segment(255)}

    {parsed, unparsed, continued_packets} = parse(page2, continued_packets)

    assert parsed == [
             %Packet{
               payload: segment(255) <> segment(255) <> segment(3),
               track_id: 0,
               bos?: false,
               eos?: false
             }
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}

    {parsed, unparsed, continued_packets} = parse(page1 <> page1 <> page2, %{})

    assert parsed == [
             %Packet{
               payload:
                 segment(255) <> segment(255) <> segment(255) <> segment(255) <> segment(3),
               track_id: 0,
               bos?: false,
               eos?: false
             }
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}
  end

  test "Handles lacing values = 0" do
    page1 = create_page([255, 0])

    {parsed, unparsed, continued_packets} = parse(page1, %{})

    assert parsed == [%Packet{payload: segment(255), track_id: 0, bos?: false, eos?: false}]
    assert unparsed == <<>>
    assert continued_packets == %{}

    page1 = create_page([0])

    {parsed, unparsed, continued_packets} = parse(page1, %{})

    assert parsed == [%Packet{payload: <<>>, track_id: 0, bos?: false, eos?: false}]
    assert unparsed == <<>>
    assert continued_packets == %{}

    page1 = create_page([2, 0])

    {parsed, unparsed, continued_packets} = parse(page1, %{})

    assert parsed == [
             %Packet{payload: segment(2), track_id: 0, bos?: false, eos?: false},
             %Packet{payload: <<>>, track_id: 0, bos?: false, eos?: false}
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}

    page1 = create_page([255])
    page2 = create_page([0, 1])

    {parsed, unparsed, continued_packets} = parse(page1 <> page2, %{})

    assert parsed == [
             %Packet{payload: segment(255), track_id: 0, bos?: false, eos?: false},
             %Packet{payload: segment(1), track_id: 0, bos?: false, eos?: false}
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}
  end

  test "Raises an error if page is corrupted (invalid crc)" do
    page = create_page_with_invalid_crc([5])
    assert_raise RuntimeError, "Corrupted stream: invalid crc", fn -> parse(page, %{}) end
  end

  test "Raises an error if page is corrupted (invalid header)" do
    page = create_page_with_invalid_header([5])
    assert_raise RuntimeError, "Corrupted stream: invalid page header", fn -> parse(page, %{}) end
  end
end
