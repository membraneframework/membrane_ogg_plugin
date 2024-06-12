defmodule PageTest do
  use ExUnit.Case, async: true

  alias Membrane.Ogg.Page

  test "create first page with a single packet" do
    page =
      Page.create_first(0)
      |> Page.append_packet!(create_packet(1))
      |> Page.finalize(0)

    assert page == %Page{
             continued: false,
             bos: true,
             eos: false,
             granule_position: 0,
             bitstream_serial_number: 0,
             page_sequence_number: 0,
             number_page_segments: 1,
             segment_table: [1],
             data: <<1::8>>
           }

    serialized_page = Page.serialize(page)

    assert <<"OggS", 0, 2, 0::64, 0::32, 0::32, _crc::32, 1, 1, 1>> = serialized_page
  end

  test "create page with multiple packets" do
    page =
      Page.create_first(0)
      |> Page.append_packet!(create_packet(3))
      |> Page.append_packet!(create_packet(4))
      |> Page.append_packet!(create_packet(5))
      |> Page.finalize(0)

    assert %Page{
             number_page_segments: 3,
             segment_table: [3, 4, 5],
             data: <<3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 5>>
           } = page

    serialized_page = Page.serialize(page)

    assert <<_beginning::26*8, 3, 3, 4, 5, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 5>> = serialized_page
  end

  test "try to create a pages with too many segments" do
    assert {:error, :not_enough_space} =
             Page.create_first(0)
             |> Page.append_packet(create_packet(255 * 255))

    assert {:ok, page} =
             Page.create_first(0)
             |> Page.append_packet(create_packet(255 * 254 + 254))

    assert {:error, :not_enough_space} =
             page
             |> Page.append_packet(create_packet(1))
  end

  @spec create_packet(non_neg_integer()) :: binary()
  defp create_packet(length) do
    <<length::8>>
    |> List.duplicate(length)
    |> Enum.join()
  end
end
