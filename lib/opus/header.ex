defmodule Membrane.Ogg.Opus.Header do
  @moduledoc false

  @id_header_signature "OpusHead"
  @version 1
  @preskip 0
  @sample_rate 48_000
  @output_gain 0
  @channel_mapping_family 0

  @comment_header_signature "OpusTags"
  @vendor "membraneframework"
  @user_comment_list_length 0

  @spec create_id_header(non_neg_integer()) :: binary()
  def create_id_header(channel_count) do
    <<@id_header_signature, @version, channel_count, @preskip::little-16, @sample_rate::little-32,
      @output_gain::little-16, @channel_mapping_family>>
  end

  @spec create_comment_header() :: binary()
  def create_comment_header() do
    <<@comment_header_signature, byte_size(@vendor)::little-32, @vendor,
      @user_comment_list_length::little-32>>
  end
end
