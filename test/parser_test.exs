defmodule ParserTest do
  use ExUnit.Case, async: true

  import Membrane.Ogg.Parser

  defp dummy_header() do
    <<"OggS", 0, 0, 0::size(8 * 8), 0::size(4 * 8), 0::size(4 * 8), 0::size(4 * 8)>>
  end

  test "Parses a simple page with a single segment" do
    page = dummy_header() <> <<1, 5, 42::size(5 * 8)>>
    {parsed, unparsed, continued_packets} = parse(page, %{})
    assert parsed == [%{payload: <<42::size(5 * 8)>>, track_id: 0, bos?: false, eos?: false}]
    assert unparsed == <<>>
    assert continued_packets == %{}
  end

  test "Parses a simple page with multiple segments" do
    page = dummy_header() <> <<2, 255, 7, 42::size(255 * 8), 21::size(7 * 8)>>

    {parsed, unparsed, continued_packets} = parse(page, %{})

    assert parsed == [
             %{
               payload: <<42::size(255 * 8), 21::size(7 * 8)>>,
               track_id: 0,
               bos?: false,
               eos?: false
             }
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}
  end

  test "Doesn't parse if input is too short" do
    page = dummy_header() <> <<2, 255, 7, 42::size(255 * 8), 21::size(7 * 8)>>

    slices = Enum.map(0..(byte_size(page) - 1), fn x -> String.slice(page, 0, x) end)
    assert Enum.all?(slices, fn x -> parse(x, %{}) == {[], x, %{}} end) == true
  end

  test "Parses multiple pages" do
    page1 = dummy_header() <> <<1, 5, 42::size(5 * 8)>>
    page2 = dummy_header() <> <<1, 3, 21::size(3 * 8)>>
    page3 = dummy_header() <> <<2, 255, 7, 90::size(255 * 8), 65::size(7 * 8)>>

    {parsed, unparsed, continued_packets} = parse(page1 <> page2, %{})

    assert parsed == [
             %{payload: <<42::size(5 * 8)>>, track_id: 0, bos?: false, eos?: false},
             %{payload: <<21::size(3 * 8)>>, track_id: 0, bos?: false, eos?: false}
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}

    {parsed, unparsed, continued_packets} = parse(page1 <> page2 <> page3, %{})

    assert parsed == [
             %{payload: <<42::size(5 * 8)>>, track_id: 0, bos?: false, eos?: false},
             %{payload: <<21::size(3 * 8)>>, track_id: 0, bos?: false, eos?: false},
             %{
               payload: <<90::size(255 * 8), 65::size(7 * 8)>>,
               track_id: 0,
               bos?: false,
               eos?: false
             }
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}
  end

  test "Parses a page with multiple packets" do
    page =
      dummy_header() <> <<3, 255, 7, 10, 42::size(255 * 8), 21::size(7 * 8), 54::size(10 * 8)>>

    {parsed, unparsed, continued_packets} = parse(page, %{})

    assert parsed == [
             %{
               payload: <<42::size(255 * 8), 21::size(7 * 8)>>,
               track_id: 0,
               bos?: false,
               eos?: false
             },
             %{payload: <<54::size(10 * 8)>>, track_id: 0, bos?: false, eos?: false}
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}
  end

  test "Parses a packet spanning through multiple pages" do
    page1 = dummy_header() <> <<2, 255, 255, 42::size(255 * 8), 21::size(255 * 8)>>
    page2 = dummy_header() <> <<1, 3, 67::size(3 * 8)>>

    {parsed, unparsed, continued_packets} = parse(page1 <> page2, %{})

    assert parsed == [
             %{
               payload: <<42::size(255 * 8), 21::size(255 * 8), 67::size(3 * 8)>>,
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
    assert continued_packets == %{0 => <<42::size(255 * 8), 21::size(255 * 8)>>}

    {parsed, unparsed, continued_packets} = parse(page2, continued_packets)

    assert parsed == [
             %{
               payload: <<42::size(255 * 8), 21::size(255 * 8), 67::size(3 * 8)>>,
               track_id: 0,
               bos?: false,
               eos?: false
             }
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}

    {parsed, unparsed, continued_packets} = parse(page1 <> page1 <> page2, %{})

    assert parsed == [
             %{
               payload:
                 <<42::size(255 * 8), 21::size(255 * 8), 42::size(255 * 8), 21::size(255 * 8),
                   67::size(3 * 8)>>,
               track_id: 0,
               bos?: false,
               eos?: false
             }
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}
  end

  test "Handles lacing values = 0" do
    page1 = dummy_header() <> <<2, 255, 0, 42::size(255 * 8)>>

    {parsed, unparsed, continued_packets} = parse(page1, %{})

    assert parsed == [%{payload: <<42::size(255 * 8)>>, track_id: 0, bos?: false, eos?: false}]
    assert unparsed == <<>>
    assert continued_packets == %{}

    page1 = dummy_header() <> <<1, 0>>

    {parsed, unparsed, continued_packets} = parse(page1, %{})

    assert parsed == [%{payload: <<>>, track_id: 0, bos?: false, eos?: false}]
    assert unparsed == <<>>
    assert continued_packets == %{}

    page1 = dummy_header() <> <<2, 2, 0, 42::size(2 * 8)>>

    {parsed, unparsed, continued_packets} = parse(page1, %{})

    assert parsed == [
             %{payload: <<42::size(2 * 8)>>, track_id: 0, bos?: false, eos?: false},
             %{payload: <<>>, track_id: 0, bos?: false, eos?: false}
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}

    page1 = dummy_header() <> <<1, 255, 42::size(255 * 8)>>
    page2 = dummy_header() <> <<2, 0, 1, 12::size(8)>>

    {parsed, unparsed, continued_packets} = parse(page1 <> page2, %{})

    assert parsed == [
             %{payload: <<42::size(255 * 8)>>, track_id: 0, bos?: false, eos?: false},
             %{payload: <<12::size(8)>>, track_id: 0, bos?: false, eos?: false}
           ]

    assert unparsed == <<>>
    assert continued_packets == %{}
  end
end
