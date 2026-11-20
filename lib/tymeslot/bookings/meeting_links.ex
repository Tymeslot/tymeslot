defmodule Tymeslot.Bookings.MeetingLinks do
  @moduledoc """
  The view, reschedule and cancel links of a booking.

  The reschedule and cancel links are the booker's, on the public booking
  pages. The view link is the organiser's: every message that carries it
  (the external-change email, chat notifications, webhook payloads) goes to
  the host, so it opens the booking in their dashboard, behind sign-in
  (`host_view_url/1`). There is no public page that shows a booking. It is
  keyed on the meeting's id, never its uid: the uid is the booker's bearer
  capability, and the view link travels to chat channels, webhook endpoints
  and inboxes the booker never chose to trust with it.

  The links are built when they are rendered, from the meeting's uid and id, the
  organiser's username *now* and the application's base URL *now*. A booking
  also stores a copy of them (`view_url`, `reschedule_url`, `cancel_url`),
  written once at booking time; that copy goes stale as soon as the host
  changes their username or the deployment moves domain, so nothing that
  shows a link to anyone reads it.

  Also here: the booker's link to a whole series (`series_url/2`), the
  links a booking's other emails carry, the guest's RSVP
  links (`guest_rsvp_urls/1`) and the host's request-review links
  (`approval_urls/1`).

  A host without a username gets the uid-only form (`/meeting/:uid/cancel`),
  which the router resolves to the host's current page once they have one.
  """

  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Utils.UrlBuilder

  @type links :: %{
          view_url: String.t() | nil,
          reschedule_url: String.t() | nil,
          cancel_url: String.t() | nil
        }

  @type page :: :cancel | :cancel_confirmed | :reschedule

  @suffixes %{
    cancel: "/cancel",
    cancel_confirmed: "/cancel-confirmed",
    reschedule: "/reschedule"
  }

  # The pages a link can be resolved to by uid; there is no public view page.
  @pages [:cancel, :cancel_confirmed, :reschedule]

  @doc """
  The links to show for `meeting`.

  A group meeting is the exception: its slot is never cancelled or moved
  through the public uid links, and the links its participants see are their
  own seat links, which `Tymeslot.Meetings.Recipient.as_seen_by/2` lays over
  the struct. Those are returned as the struct carries them.
  """
  @spec for_meeting(map()) :: links()
  def for_meeting(meeting), do: links(meeting, &current_username/1)

  @doc """
  `for_meeting/1` for a caller already holding the organiser's profile
  (`nil` when they have none), which saves reading it again.
  """
  @spec for_meeting(map(), map() | nil) :: links()
  def for_meeting(meeting, organizer_profile),
    do: links(meeting, fn _user_id -> organizer_profile && organizer_profile.username end)

  defp links(%MeetingSchema{capacity: capacity, uid: uid} = meeting, _username_fn)
       when is_integer(capacity) and capacity > 1 do
    meeting
    |> Map.take([:view_url, :reschedule_url, :cancel_url])
    |> Map.put(:view_url, uid && view_url(meeting))
  end

  defp links(%{uid: uid} = meeting, username_fn) when is_binary(uid) do
    meeting
    |> Map.get(:organizer_user_id)
    |> username_fn.()
    |> build(uid)
    |> Map.put(:view_url, view_url(meeting))
  end

  # Without a uid there is nothing to link to; whatever the map carries stands.
  defp links(meeting, _username_fn) when is_map(meeting) do
    %{
      view_url: Map.get(meeting, :view_url),
      reschedule_url: Map.get(meeting, :reschedule_url),
      cancel_url: Map.get(meeting, :cancel_url)
    }
  end

  @doc """
  `meeting` with its link fields replaced by `for_meeting/1`, for templates
  that render straight from the meeting struct.
  """
  @spec with_current_links(map()) :: map()
  def with_current_links(meeting) when is_map(meeting),
    do: Map.merge(meeting, for_meeting(meeting))

  @doc """
  The links for a booking with `uid` whose organiser is called `username`.

  Used at booking time to fill the stored columns, and by `for_meeting/1`.
  The booking has no id yet at that point, so its `view_url` is the
  organiser's meetings list; `for_meeting/1` narrows it to the booking.
  """
  @spec build(String.t() | nil, String.t()) :: %{
          view_url: String.t(),
          reschedule_url: String.t(),
          cancel_url: String.t()
        }
  def build(username, uid) when is_binary(uid) do
    %{
      view_url: meetings_list_url(),
      reschedule_url: url(username, uid, :reschedule),
      cancel_url: url(username, uid, :cancel)
    }
  end

  @doc """
  The organiser's link to the booking with id `meeting_id`: their
  dashboard's meetings list showing that booking alone. Built from the
  application's base URL now, never read from the stored `view_url`.
  """
  @spec host_view_url(Ecto.UUID.t()) :: String.t()
  def host_view_url(meeting_id) when is_binary(meeting_id),
    do: UrlBuilder.build_url("/dashboard/meetings?" <> URI.encode_query(meeting: meeting_id))

  defp view_url(%{id: id}) when is_binary(id), do: host_view_url(id)
  defp view_url(_unsaved), do: meetings_list_url()

  defp meetings_list_url, do: UrlBuilder.build_url("/dashboard/meetings")

  @doc """
  The booker's link to the page managing every session of `series`, on the
  organiser's public pages: `/:username/series/:series_uid`, built from the
  username in `organizer_profile` (the organiser's current profile, `nil`
  when they have none) and the application's base URL now, as the meeting
  links are. The series uid is the bearer of the page.

  `nil` for an organiser without a username: the uid-only form
  (`/series/:series_uid`, `current_series_path/1`) resolves only once they
  have one, and an email leaves a link without a URL out.
  """
  @spec series_url(%{:uid => String.t(), optional(atom()) => term()}, map() | nil) ::
          String.t() | nil
  def series_url(%{uid: uid}, %{username: username})
      when is_binary(uid) and is_binary(username) and username != "",
      do: UrlBuilder.base_url() <> "/#{username}/series/#{uid}"

  def series_url(_series, _organizer_profile), do: nil

  @doc """
  Where the series page for the series with bearer `uid` lives now, as a
  path: the organiser's current username, however the link was addressed
  (`/series/:series_uid`, or a username the host has since given up), as
  `current_path/2` resolves a meeting's. `{:error, :not_found}` when no
  series has that uid or its organiser has no username.
  """
  @spec current_series_path(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def current_series_path(uid) when is_binary(uid) do
    case SeriesQueries.organizer_username_by_uid(uid) do
      {:ok, username} -> {:ok, "/#{username}/series/#{uid}"}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Where `page` for the booking with `uid` lives now, as a path.

  Resolves the organiser by the meeting rather than by any username in the
  link, so a link built before the host renamed themselves, or before they
  had a username at all, still reaches the page. The uid is what authorises
  the page, so answering from it reveals nothing the link did not already
  grant. `{:error, :not_found}` when no meeting has that uid or its organiser
  has no username.
  """
  @spec current_path(String.t(), page()) :: {:ok, String.t()} | {:error, :not_found}
  def current_path(uid, page) when is_binary(uid) and page in @pages do
    case MeetingQueries.organizer_username_by_uid(uid) do
      {:ok, username} -> {:ok, path(username, uid, page)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  The organiser's public booking page, for someone to book them afresh: the
  application's root when the organiser has no username to address it by.
  """
  @spec booking_page_url(map()) :: String.t()
  def booking_page_url(meeting) do
    case current_username(Map.get(meeting, :organizer_user_id)) do
      username when is_binary(username) and username != "" ->
        UrlBuilder.build_url("/" <> username)

      _no_username ->
        UrlBuilder.base_url()
    end
  end

  defp url(username, uid, action), do: UrlBuilder.base_url() <> path(username, uid, action)

  defp path(username, uid, action) when is_binary(username) and username != "",
    do: "/#{username}/meeting/#{uid}#{Map.fetch!(@suffixes, action)}"

  defp path(_no_username, uid, action), do: "/meeting/#{uid}#{Map.fetch!(@suffixes, action)}"

  defp current_username(nil), do: nil

  defp current_username(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, profile} -> profile.username
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Builds the public accept/decline RSVP URLs for a guest's token.
  """
  @spec guest_rsvp_urls(String.t()) :: %{accept_url: String.t(), decline_url: String.t()}
  def guest_rsvp_urls(token) when is_binary(token) do
    %{
      accept_url: UrlBuilder.base_url() <> "/guest/#{token}/accept",
      decline_url: UrlBuilder.base_url() <> "/guest/#{token}/decline"
    }
  end

  @doc """
  Where an attendee confirms their email address for a held booking.

  Opening the page never confirms anything: the attendee presses the button
  there, so a mail scanner that fetches the link cannot verify for them.
  """
  @spec verification_url(String.t()) :: String.t()
  def verification_url(token) when is_binary(token) do
    UrlBuilder.base_url() <> "/verify-booking/" <> token
  end

  @doc """
  Where a host answers a booking request from their email.

  Both actions point at the same review page. The `intent` parameter only
  preselects a choice for the host to confirm — it never acts on its own,
  because mail security scanners and link preview crawlers fetch every URL in
  an inbound message and would otherwise answer the request for them.
  """
  @spec approval_urls(String.t()) :: %{
          review_url: String.t(),
          approve_url: String.t(),
          decline_url: String.t()
        }
  def approval_urls(token) when is_binary(token) do
    review_url = UrlBuilder.base_url() <> "/meeting-request/#{token}"

    %{
      review_url: review_url,
      approve_url: review_url <> "?intent=approve",
      decline_url: review_url <> "?intent=decline"
    }
  end
end
