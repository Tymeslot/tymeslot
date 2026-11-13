defmodule Tymeslot.Emails.Shared.SeriesSessions do
  @moduledoc """
  The numbered list of a booking series' sessions, the one block every
  series email renders, in HTML (`html/3`) and plain text (`text/3`).

  Each session is the payload `Tymeslot.Emails.AppointmentBuilder` builds
  for it, with its `:position` in the series and `:video_pending` (see
  `Tymeslot.Emails.SeriesBuilder`). It lists when the session is, in the
  reader's timezone and clock, where it is (its join link, or the location),
  and the reader's links for it:

    * the booker (`:attendee`) gets the session's own reschedule and cancel
      links: the booking's, or on a group type their seat's;
    * the organiser (`:organizer`) gets the session in their dashboard.

  `links: false` leaves out every link, the join link included, for a list
  of sessions that are cancelled. A session marked `cancelled: true` in a
  list of booked ones says so in place of where it is, and has no links.
  Rendered in the caller's Gettext locale.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Cards, Formatting, JoinUrl, Sanitise, Styles}

  @type audience :: :attendee | :organizer

  @doc "The sessions as one card each, numbered by their place in the series."
  @spec html([map()], audience(), String.t(), keyword()) :: String.t()
  def html(sessions, audience, locale, opts \\ []) do
    Enum.map_join(sessions, "\n", fn session ->
      opts = session_opts(session, opts)

      lines =
        [Sanitise.sanitize_for_email(session_time(session, audience, locale))] ++
          [place_html(session, audience, opts)] ++
          links_html(session, audience, opts)

      Cards.details_card(title(session), lines |> Enum.reject(&(&1 in [nil, ""])) |> join_br())
    end)
  end

  @doc "The sessions as numbered plain-text paragraphs."
  @spec text([map()], audience(), String.t(), keyword()) :: String.t()
  def text(sessions, audience, locale, opts \\ []) do
    Enum.map_join(sessions, "\n\n", fn session ->
      opts = session_opts(session, opts)

      [
        title(session),
        session_time(session, audience, locale),
        place_text(session, audience, opts)
      ]
      |> Enum.concat(links_text(session, audience, opts))
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end)
  end

  defp title(session) do
    dgettext("emails_booking_series", "Session %{position} of %{count}",
      position: session.position,
      count: session.series_count
    )
  end

  defp session_time(session, :attendee, locale),
    do: Formatting.format_datetime(session.start_time_attendee_tz, locale)

  defp session_time(session, :organizer, locale),
    do:
      Formatting.format_datetime(
        session.start_time_owner_tz,
        locale,
        Map.get(session, :organizer_time_format)
      )

  defp session_opts(%{cancelled: true}, opts), do: Keyword.put(opts, :links, false)
  defp session_opts(_session, opts), do: opts

  # Where the session is: its join link, the promise of one when its room is
  # still being made, or its location; or that it is no longer happening.
  defp place(%{cancelled: true}, _audience, _opts),
    do: {:text, dgettext("emails_booking_series", "This session has been cancelled.")}

  defp place(session, audience, opts) do
    case links?(opts) && JoinUrl.for(audience, session) do
      url when is_binary(url) -> {:join, url}
      _no_link -> unjoinable_place(session, opts)
    end
  end

  defp unjoinable_place(%{video_pending: true}, opts) do
    if links?(opts),
      do: {:text, dgettext("emails_booking_series", "The join link will be in your reminder.")},
      else: {:text, dgettext("emails", "Video Call")}
  end

  defp unjoinable_place(session, _opts), do: {:text, Formatting.format_location(session)}

  defp place_html(session, audience, opts) do
    case place(session, audience, opts) do
      {:join, url} -> link_html(dgettext("emails_booking_series", "Join the video call"), url)
      {:text, text} -> Sanitise.sanitize_for_email(text)
    end
  end

  defp place_text(session, audience, opts) do
    case place(session, audience, opts) do
      {:join, url} ->
        if Sanitise.safe_web_url?(url),
          do: "#{dgettext("emails_booking_series", "Join the video call")}: #{url}"

      {:text, text} ->
        text
    end
  end

  defp links?(opts), do: Keyword.get(opts, :links, true)

  defp links(session, audience, opts),
    do: if(links?(opts), do: session_links(session, audience), else: [])

  defp session_links(session, :attendee) do
    [
      {dgettext("emails_booking_series", "Reschedule"), Map.get(session, :reschedule_url)},
      {dgettext("emails_booking_series", "Cancel"), Map.get(session, :cancel_url)}
    ]
  end

  defp session_links(session, :organizer),
    do: [
      {dgettext("emails_booking_series", "Open in dashboard"), Map.get(session, :dashboard_url)}
    ]

  defp links_html(session, audience, opts) do
    case session
         |> links(audience, opts)
         |> Enum.map(fn {text, url} -> link_html(text, url) end) do
      [] -> []
      anchors -> [anchors |> Enum.reject(&(&1 == "")) |> Enum.join(" &middot; ")]
    end
  end

  defp links_text(session, audience, opts) do
    for {text, url} <- links(session, audience, opts),
        Sanitise.safe_url?(url),
        do: "#{text}: #{url}"
  end

  defp link_html(text, url) do
    case Sanitise.sanitize_url(url) do
      nil ->
        ""

      safe_url ->
        ~s(<a href="#{safe_url}" style="color: #{Styles.component_color(:link)}; text-decoration: underline;">#{Sanitise.sanitize_for_email(text)}</a>)
    end
  end

  defp join_br(lines), do: Enum.join(lines, "<br/>\n")
end
