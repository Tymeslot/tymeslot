defmodule Tymeslot.Utils.QrCode do
  @moduledoc """
  QR codes for a URL, drawn server-side with `EQRCode`.

  `png/1` is for email, where the image travels as an inline attachment
  (many clients block `data:` images). `svg_data_uri/1` is for pages, where
  it can be used directly as an `<img src>`.
  """

  @png_width 320
  @svg_width 240

  @doc "The QR code for `url` as PNG bytes."
  @spec png(String.t()) :: binary()
  def png(url) when is_binary(url) do
    url |> EQRCode.encode() |> EQRCode.png(width: @png_width)
  end

  @doc "The QR code for `url` as a base64 `data:image/svg+xml` URI."
  @spec svg_data_uri(String.t()) :: String.t()
  def svg_data_uri(url) when is_binary(url) do
    svg = url |> EQRCode.encode() |> EQRCode.svg(width: @svg_width)
    "data:image/svg+xml;base64," <> Base.encode64(svg)
  end
end
