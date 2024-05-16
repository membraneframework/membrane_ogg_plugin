defmodule ParserTest do
  use ExUnit.Case, async: true

  import Membrane.Ogg.Parser
  alias Membrane.Ogg.Parser.Packet

  defp create_page(segments, granule_position \\ 1) do
    segment_table = Enum.map_join(segments, fn seg -> <<seg>> end)
    content = Enum.map_join(segments, fn seg -> segment(seg) end)

    before_crc =
      <<"OggS", 0, 0, granule_position::little-size(8 * 8), 0::size(4 * 8), 0::size(4 * 8)>>

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

  test "simple page with a single segment" do
    page = create_page([5])
    {parsed, continued_packet, rest} = parse(page, nil)

    assert parsed == [
             %Packet{payload: segment(5), bos?: false, eos?: false}
           ]

    assert rest == <<>>
    assert continued_packet == nil
  end

  test "simple page with multiple segments" do
    page = create_page([255, 7])

    {parsed, continued_packet, rest} = parse(page, nil)

    assert parsed == [
             %Packet{
               payload: segment(255) <> segment(7),
               bos?: false,
               eos?: false
             }
           ]

    assert rest == <<>>
    assert continued_packet == nil
  end

  test "too short input" do
    page = create_page([255, 7, 3])

    slices = Enum.map(0..(byte_size(page) - 1), fn x -> String.slice(page, 0, x) end)
    assert Enum.all?(slices, fn x -> parse(x, nil) == {[], nil, x} end) == true
  end

  test "multiple pages" do
    page1 = create_page([5])
    page2 = create_page([3])
    page3 = create_page([255, 7])

    {parsed, continued_packet, rest} = parse(page1 <> page2, nil)

    assert parsed == [
             %Packet{payload: segment(5), bos?: false, eos?: false},
             %Packet{
               payload: segment(3),
               bos?: false,
               eos?: false
             }
           ]

    assert rest == <<>>
    assert continued_packet == nil

    {parsed, continued_packet, rest} = parse(page1 <> page2 <> page3, nil)

    assert parsed == [
             %Packet{payload: segment(5), bos?: false, eos?: false},
             %Packet{
               payload: segment(3),
               bos?: false,
               eos?: false
             },
             %Packet{
               payload: segment(255) <> segment(7),
               bos?: false,
               eos?: false
             }
           ]

    assert rest == <<>>
    assert continued_packet == nil
  end

  test "page with multiple packets" do
    page = create_page([255, 7, 10])

    {parsed, continued_packet, rest} = parse(page, nil)

    assert parsed == [
             %Packet{
               payload: segment(255) <> segment(7),
               bos?: false
             },
             %Packet{payload: segment(10), bos?: false, eos?: false}
           ]

    assert rest == <<>>
    assert continued_packet == nil
  end

  test "packet spanning through multiple pages" do
    page1 = create_page([255, 255], -1)
    page2 = create_page([3])

    {parsed, continued_packet, rest} = parse(page1 <> page2, nil)

    assert parsed == [
             %Packet{
               payload: segment(255) <> segment(255) <> segment(3),
               bos?: false,
               eos?: false
             }
           ]

    assert rest == <<>>
    assert continued_packet == nil

    {parsed, continued_packet, rest} = parse(page1, nil)

    assert parsed == []
    assert rest == <<>>
    assert continued_packet == segment(255) <> segment(255)

    {parsed, continued_packet, rest} = parse(page2, continued_packet)

    assert parsed == [
             %Packet{
               payload: segment(255) <> segment(255) <> segment(3),
               bos?: false,
               eos?: false
             }
           ]

    assert rest == <<>>
    assert continued_packet == nil

    {parsed, continued_packet, rest} = parse(page1 <> page1 <> page2, nil)

    assert parsed == [
             %Packet{
               payload:
                 segment(255) <> segment(255) <> segment(255) <> segment(255) <> segment(3),
               bos?: false,
               eos?: false
             }
           ]

    assert rest == <<>>
    assert continued_packet == nil
  end

  test "lacing values = 0" do
    page1 = create_page([255, 0])

    {parsed, continued_packet, rest} = parse(page1, nil)

    assert parsed == [
             %Packet{
               payload: segment(255),
               bos?: false,
               eos?: false
             }
           ]

    assert rest == <<>>
    assert continued_packet == nil

    page1 = create_page([0])

    {parsed, continued_packet, rest} = parse(page1, nil)

    assert parsed == [
             %Packet{payload: <<>>, bos?: false, eos?: false}
           ]

    assert rest == <<>>
    assert continued_packet == nil

    page1 = create_page([2, 0])

    {parsed, continued_packet, rest} = parse(page1, nil)

    assert parsed == [
             %Packet{payload: segment(2), bos?: false, eos?: false},
             %Packet{payload: <<>>, bos?: false, eos?: false}
           ]

    assert rest == <<>>
    assert continued_packet == nil

    page1 = create_page([255], -1)
    page2 = create_page([0, 1])

    {parsed, continued_packet, rest} = parse(page1 <> page2, nil)

    assert parsed == [
             %Packet{
               payload: segment(255),
               bos?: false,
               eos?: false
             },
             %Packet{payload: segment(1), bos?: false, eos?: false}
           ]

    assert rest == <<>>
    assert continued_packet == nil
  end

  test "corrupted page (invalid crc)" do
    page = create_page_with_invalid_crc([5])
    assert_raise RuntimeError, "Corrupted stream: invalid crc", fn -> parse(page, nil) end
  end

  test "corrupted page (invalid header)" do
    page = create_page_with_invalid_header([5])

    assert_raise RuntimeError, "Corrupted stream: invalid page header", fn ->
      parse(page, nil)
    end
  end
end
