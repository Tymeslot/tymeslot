defmodule Tymeslot.Emails.Shared.Meeting.Description do
  @moduledoc """
  The description the organiser wrote for a meeting: a booked meeting's
  meeting type description, or the description of an event on the dashboard
  calendar. It is where an organiser says what to bring or prepare, so every
  email that describes the meeting shows it, under one heading, when there is
  one.

  The join link has its own section in every such email, so the "Join video
  call" line a provider event carries in its description is taken out here.
  """

  alias Tymeslot.CalendarGrid.EventVideo
  alias Tymeslot.Emails.Shared.Cards

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  The description in `details`, without its join line and markup; nil when
  nothing is left.
  """
  @spec text(map()) :: String.t() | nil
  def text(details) do
    text =
      details
      |> Map.get(:description)
      |> EventVideo.without_join_lines()

    case text && text |> plain_text() |> String.trim() do
      "" -> nil
      stripped -> stripped
    end
  end

  # `strip_tags/1` parses the markup (decoding its entities) and re-escapes
  # `&`, `<` and `>` in what is left. Every caller escapes for its own output
  # and the text part needs none, so the escaping is undone here; otherwise a
  # host's "Q&A" reaches the guest as "Q&amp;A".
  @entities %{"amp" => "&", "lt" => "<", "gt" => ">"}

  defp plain_text(text) do
    Regex.replace(~r/&(amp|lt|gt);/, HtmlSanitizeEx.strip_tags(text), fn _match, name ->
      Map.fetch!(@entities, name)
    end)
  end

  @doc """
  The description as an HTML card, or `""` when there is none. Must be
  called within a `Gettext.with_locale` block.
  """
  @spec section(map()) :: String.t()
  def section(details) do
    case text(details) do
      nil -> ""
      text -> Cards.message_content_card(dgettext("emails", "Description"), text)
    end
  end

  @doc """
  The text body's counterpart of `section/1`, led by a blank line; `""` when
  there is none. Must be called within a `Gettext.with_locale` block.
  """
  @spec text_section(map()) :: String.t()
  def text_section(details) do
    case text(details) do
      nil -> ""
      text -> "\n\n#{dgettext("emails", "DESCRIPTION:")}\n#{text}"
    end
  end
end
