defmodule Tymeslot.Emails.Shared.CalendarEventContent do
  @moduledoc """
  What the calendar invitation and the event update email say alike about an
  event on the organiser's dashboard calendar, from the details map
  `Tymeslot.Notifications.Email.CalendarEventDetails` builds: the hero's
  details, how the event repeats, the description the organiser wrote, and
  the fields of the ICS attachment.

  The join link is stated once, in its own section and in the attachment's
  `CONFERENCE`, so the "Join video call" line the provider event carries in
  its description is taken out wherever the description is shown. A
  cancelled event has no meeting left to join, so it states no link at all.
  """

  alias Tymeslot.CalendarGrid.EventVideo
  alias Tymeslot.Emails.Shared.{Callouts, Cards, MjmlEmail, Sanitise}
  alias Tymeslot.Emails.Shared.Styles.Tokens
  alias Tymeslot.Integrations.Calendar.Recurrence.Summary

  import Swoosh.Email, only: [from: 2]

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Sends `email` in the organiser's name from the instance's address: the
  guest was added by a person, not by the instance, and the address stays
  the one SPF and DKIM vouch for.
  """
  @spec from_organiser(Swoosh.Email.t(), map()) :: Swoosh.Email.t()
  def from_organiser(email, %{organizer_name: name}) when is_binary(name) and name != "",
    do: from(email, {Sanitise.sanitize_for_header(name), MjmlEmail.fetch_from_email()})

  def from_organiser(email, _details), do: email

  @doc """
  The hero's meeting details (`Tymeslot.Emails.Shared.MeetingComponents.meeting_details_table/2`):
  the event's title is shown as the event, not as a meeting type.
  """
  @spec hero_details(map()) :: map()
  def hero_details(details) do
    details
    |> Map.take([:all_day, :last_date])
    |> Map.merge(%{
      date: details.date,
      start_time: details.start_time,
      duration: details.duration,
      location: details.location,
      location_type: location_type(details),
      event_title: details.event_title
    })
  end

  # A written location wins; an event with only a video room is a video call.
  defp location_type(%{location: location}) when is_binary(location) and location != "",
    do: :in_person

  defp location_type(details), do: if(join_link(details), do: :video)

  @doc "The event's join link, or nil for none and for a cancellation."
  @spec join_link(map()) :: String.t() | nil
  def join_link(details),
    do: if(not cancellation?(details), do: Map.get(details, :video_link))

  @doc "Whether the details describe the cancellation of the event for the recipient."
  @spec cancellation?(map()) :: boolean()
  def cancellation?(details), do: Map.get(details, :method) == :cancel

  @doc """
  The description the organiser wrote, without its join line and markup;
  nil when nothing is left.
  """
  @spec description(map()) :: String.t() | nil
  def description(details) do
    text =
      details
      |> Map.get(:description)
      |> EventVideo.without_join_lines()

    case text && text |> HtmlSanitizeEx.strip_tags() |> String.trim() do
      "" -> nil
      stripped -> stripped
    end
  end

  @doc """
  How a repeating event repeats, in the current Gettext locale ("Repeats
  weekly on Tuesday"); nil for a single event.
  """
  @spec repeats(map()) :: String.t() | nil
  def repeats(%{recurrence_rule: rule} = details) when is_binary(rule) and rule != "",
    do: Summary.describe(rule, series_start(details))

  def repeats(_details), do: nil

  defp series_start(%{all_day: true, start_date: start_date}), do: start_date
  defp series_start(details), do: details.start_time

  @doc """
  The HTML sections under the hero: how the event repeats, and its
  description. Must be called within a `Gettext.with_locale` block.
  """
  @spec body_sections(map(), Tokens.intent()) :: String.t()
  def body_sections(details, intent) do
    repeats_html =
      case repeats(details) do
        nil -> ""
        summary -> Callouts.alert_box(intent, summary)
      end

    description_html =
      case description(details) do
        nil -> ""
        text -> Cards.message_content_card(dgettext("emails", "Description"), text)
      end

    repeats_html <> "\n" <> description_html
  end

  @doc """
  The text body's counterpart of `body_sections/2`, as lines to place under
  the meeting details; `""` when there is neither.
  """
  @spec text_sections(map()) :: String.t()
  def text_sections(details) do
    [
      repeats(details),
      case description(details) do
        nil -> nil
        text -> "\n#{dgettext("emails", "DESCRIPTION:")}\n#{text}"
      end
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  The fields of the ICS attachment for `attendee_email`. The SEQUENCE is the
  details' `:sequence`, so an invitation sent again after a removal
  supersedes the cancellation the guest's calendar holds.

  The attachment is always a single event, even for a series: the email
  says how it repeats, but no RRULE is written. A rule needs a DTSTART in
  the series' own zone (BYDAY is a local weekday, and a UTC start moves an
  hour at every DST change), and the updates and cancellations that follow
  are keyed by occurrence, with no RECURRENCE-ID, so none of them could
  reach a repeating entry in the guest's calendar.
  """
  @spec ics_details(map(), String.t()) :: map()
  def ics_details(details, attendee_email) do
    %{
      all_day: Map.get(details, :all_day, false),
      start_date: Map.get(details, :start_date),
      end_date: Map.get(details, :end_date),
      title: details.event_title,
      start_time: details.start_time,
      end_time: details.end_time,
      uid: details.event_uid,
      ical_uid: Map.get(details, :ical_uid),
      other_entries: Map.get(details, :other_entries, []),
      location: details.location,
      meeting_url: join_link(details),
      # The attachment states the link itself, in CONFERENCE and its own
      # description line, so the provider's join line is left out.
      description: EventVideo.without_join_lines(Map.get(details, :description)),
      ical_sequence: Map.get(details, :sequence),
      organizer_name: details.organizer_name,
      organizer_email: details.organizer_email,
      organizer_user_id: Map.get(details, :organizer_user_id),
      attendee_email: attendee_email
    }
  end
end
