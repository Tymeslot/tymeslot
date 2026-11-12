defmodule Tymeslot.Bookings.BookingTitle do
  @moduledoc """
  The title a booking is given, "<meeting type> with <name>", and the same
  title in another reader's language.

  A booking's `title` is stored once, in the organiser's language, because it
  becomes the organiser's calendar event and dashboard entry. The booker and
  their guests read it too, in their emails and the `.ics` attached to them,
  so `localise/1` renders it again in the current Gettext locale for them.

  Only a title this template built is rendered again. A title that does not
  match the template in any language (one renamed in the calendar grid, a
  demo booking's, or one whose attendee name has since been edited) is the
  stored text, and is returned as it is.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc "The booking title, rendered in the current Gettext locale."
  @spec render(String.t() | nil, String.t() | nil) :: String.t()
  def render(meeting_type, attendee_name) do
    dgettext("emails", "%{meeting_type} with %{name}",
      meeting_type: meeting_type,
      name: attendee_name
    )
  end

  @doc """
  The meeting's title in the current Gettext locale when this template built
  it, otherwise its stored `title` unchanged.
  """
  @spec localise(map()) :: String.t() | nil
  def localise(%{title: title, meeting_type: meeting_type, attendee_name: attendee_name})
      when is_binary(title) and is_binary(meeting_type) and is_binary(attendee_name) do
    if built_from_template?(title, meeting_type, attendee_name),
      do: render(meeting_type, attendee_name),
      else: title
  end

  def localise(meeting), do: Map.get(meeting, :title)

  @doc "`localise/1` in `locale`."
  @spec localise(map(), String.t()) :: String.t() | nil
  def localise(meeting, locale),
    do: Gettext.with_locale(TymeslotWeb.Gettext, locale, fn -> localise(meeting) end)

  @doc """
  `localise/1` with the meeting type named `display_type`, the name as the
  reader sees it (the attendee's translation of it,
  `Tymeslot.ContentTranslations.AttendeeTexts`). The template is still
  detected from the stored, original name, so a title it did not build is
  returned unchanged.
  """
  @spec localise_with_type(map(), String.t() | nil) :: String.t() | nil
  def localise_with_type(
        %{title: title, meeting_type: meeting_type, attendee_name: attendee_name} = meeting,
        display_type
      )
      when is_binary(title) and is_binary(meeting_type) and is_binary(attendee_name) and
             is_binary(display_type) do
    if built_from_template?(title, meeting_type, attendee_name),
      do: render(display_type, attendee_name),
      else: localise(meeting)
  end

  def localise_with_type(meeting, _display_type), do: localise(meeting)

  # Every catalogue is tried, not only the organiser's current language: the
  # title was rendered in whatever language they had when the booking was
  # made, and bookings older than the translated title hold the English one.
  defp built_from_template?(title, meeting_type, attendee_name) do
    TymeslotWeb.Gettext
    |> Gettext.known_locales()
    |> Enum.any?(fn locale ->
      Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
        render(meeting_type, attendee_name)
      end) == title
    end)
  end
end
