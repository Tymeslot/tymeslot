defmodule Tymeslot.Utils.QrCodeTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias Tymeslot.Utils.QrCode

  @url "https://example.com/anna"

  test "returns a PNG and an SVG data URI" do
    assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>> = QrCode.png(@url)
    assert String.starts_with?(QrCode.svg_data_uri(@url), "data:image/svg+xml;base64,")
  end
end
