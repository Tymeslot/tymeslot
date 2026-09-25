defmodule Tymeslot.Emails.Shared.AvatarHelper do
  @moduledoc """
  Renders the organiser avatar in the email organiser strip.

  An uploaded avatar arrives as an absolute http(s) URL and renders as an
  image. Anything else renders an initials badge built from plain HTML rather
  than a generated image: Gmail strips `data:` URI images, so an inline SVG
  shows up there as broken alt text.
  """

  alias Tymeslot.Emails.Shared.{Sanitise, Styles}
  alias Tymeslot.Emails.Shared.Styles.Tokens
  alias Tymeslot.Security.UrlValidation

  @size_px 44

  @doc """
  Returns the MJML for the organiser avatar: an `mj-image` when `avatar_url`
  is an absolute http(s) URL, otherwise an initials badge for `organizer_name`.
  """
  @spec avatar_mjml(String.t() | nil, String.t() | nil) :: String.t()
  def avatar_mjml(avatar_url, organizer_name) when is_binary(avatar_url) do
    case UrlValidation.validate_http_url(avatar_url) do
      :ok -> image_mjml(avatar_url, organizer_name)
      _invalid -> initials_badge_mjml(organizer_name)
    end
  end

  def avatar_mjml(_no_url, organizer_name), do: initials_badge_mjml(organizer_name)

  @doc """
  The initials shown in the badge: the first letters of the first and last
  words of the name, so a long name still fits the circle.
  """
  @spec initials(String.t() | nil) :: String.t()
  def initials(organizer_name) do
    case String.split(organizer_name || "") do
      [] -> "U"
      [only] -> first_letter(only)
      [first | rest] -> first_letter(first) <> first_letter(List.last(rest))
    end
  end

  defp first_letter(word), do: word |> String.first() |> String.upcase()

  defp image_mjml(avatar_url, organizer_name) do
    """
    <mj-image
      src="#{Sanitise.sanitize_for_email(avatar_url)}"
      width="#{@size_px}px"
      height="#{@size_px}px"
      border-radius="#{div(@size_px, 2)}px"
      alt="#{Sanitise.sanitize_for_email(organizer_name || "")}"
      align="left"
      padding="0"
    />
    """
  end

  # A table cell rather than a div: Outlook ignores height on a div, so only a
  # cell keeps the badge square (and round wherever border-radius is honoured).
  defp initials_badge_mjml(organizer_name) do
    accent_deep = Tokens.intent_accent_deep(:confirmed)

    """
    <mj-text padding="0" align="left">
      <table role="presentation" cellpadding="0" cellspacing="0" border="0">
        <tr>
          <td
            width="#{@size_px}"
            height="#{@size_px}"
            align="center"
            valign="middle"
            style="width:#{@size_px}px;height:#{@size_px}px;border-radius:#{div(@size_px, 2)}px;background-color:#{accent_deep};color:#{Styles.button_text_color(accent_deep)};font-size:17px;font-weight:600;line-height:#{@size_px}px;text-align:center;"
          >#{Sanitise.sanitize_for_email(initials(organizer_name))}</td>
        </tr>
      </table>
    </mj-text>
    """
  end
end
