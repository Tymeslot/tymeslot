defmodule TymeslotWeb.Helpers.ImageUploadErrors do
  @moduledoc """
  User-facing messages for the reasons `Tymeslot.Media.ImageMetadata.strip/3`
  refuses a stored image, shared by every image upload (avatars in the
  dashboard and in onboarding, theme backgrounds).

  Only the refusals a user can act on have a message of their own: an image
  whose dimensions are over the bound, and a node too busy with other uploads
  to take this one. Every other reason returns `nil`, leaving the caller's own
  generic failure message in place.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Helpers.LocaleFormat

  @megapixel 1_000_000

  @doc """
  The message to show for an image upload refused for `reason`, or `nil` when
  the reason has no specific message.
  """
  @spec message(term()) :: String.t() | nil
  def message({:image_too_large, %{pixels: pixels, max_pixels: max_pixels}}) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)

    dgettext(
      "errors",
      "This image is too large (%{size} megapixels). Please upload an image of at most %{limit} megapixels.",
      size: LocaleFormat.format_number(megapixels_rounded_up(pixels), locale, 1),
      limit: LocaleFormat.format_integer(div(max_pixels, @megapixel), locale)
    )
  end

  def message(:busy) do
    dgettext(
      "errors",
      "We are busy processing other uploads. Please try again in a moment."
    )
  end

  def message(_reason), do: nil

  # Rounded up so an image just over the bound never reads as being at it:
  # 40,008,000 pixels shows as 40.1 megapixels against a limit of 40, not 40.0.
  defp megapixels_rounded_up(pixels), do: Float.ceil(pixels / @megapixel, 1)
end
