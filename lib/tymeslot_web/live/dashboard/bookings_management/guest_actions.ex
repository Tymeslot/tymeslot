defmodule TymeslotWeb.Dashboard.BookingsManagement.GuestActions do
  @moduledoc """
  Adding guests to a booking that already exists.

  The host's own path, which is why the meeting type's `allow_guests` is not
  consulted: that setting governs the public booking form. `Bookings.CreateAdHoc`
  makes the same distinction when a host books on someone's behalf.

  Mail is left to `Meetings.Guests` and the email job: every guest carries its
  own `confirmation_sent_at`, so a guest added now is invited and the guests
  already there are not written to again.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Emails.EmailScheduler.MeetingScheduler
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Guests
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash

  require Logger

  @doc """
  Splits what the host typed into candidate addresses.

  Accepts the separators a person actually reaches for when listing
  colleagues — newlines, commas, semicolons and plain spaces — because the
  field is free text rather than a list of inputs. Validation, de-duplication
  and the cap belong to `Meetings.Guests`; this only decides where one address
  ends and the next begins.
  """
  @spec parse_emails(String.t() | nil) :: [String.t()]
  def parse_emails(nil), do: []

  def parse_emails(raw) when is_binary(raw) do
    raw
    |> String.split([",", ";", "\n", "\r", " ", "\t"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Opens the dialog for the booking `meeting_id` names.

  The meeting is read fresh rather than taken from the list, so the guests it
  shows are the guests it has — a card rendered before someone else added one
  would otherwise offer a stale count. A booking that has since disappeared
  simply reloads the list.
  """
  @spec open(Phoenix.LiveView.Socket.t(), binary(), (Phoenix.LiveView.Socket.t() ->
                                                       Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def open(socket, meeting_id, reload) when is_function(reload, 1) do
    case Meetings.get_meeting(meeting_id) do
      {:ok, meeting} ->
        # The guest list is fetched rather than taken off the meeting: this row
        # is read fresh, and nothing preloads its guests, which silently read
        # as "none" — and so as a full meeting with no room left.
        socket
        |> assign(:staged_guests, [])
        |> assign(:add_guests_existing, Guests.list_for_meeting(meeting.id))
        |> ModalHook.show_modal(:add_guests, meeting)

      {:error, :not_found} ->
        reload.(socket)
    end
  end

  @doc """
  Puts an address on the list the dialog is building, without inviting anyone
  yet.

  Addresses are collected one at a time, as they are everywhere else in the
  app. Pasting several at once still works — `parse_emails/1` splits them —
  because a host copying a line out of an email should not have to take it
  apart by hand.

  An address already on the meeting, or already staged, is refused rather than
  added twice, and the list stops at the meeting's remaining room.
  """
  @spec stage(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def stage(socket, raw_email) do
    ModalHook.with_modal_data(socket, :add_guests, fn meeting ->
      staged = staged(socket)
      existing = existing(socket)
      known = MapSet.new(Enum.map(existing, &String.downcase(&1.email)))

      additions =
        raw_email
        |> parse_emails()
        |> Guests.sanitize_emails(meeting.attendee_email)
        |> Enum.reject(&(&1 in staged or MapSet.member?(known, &1)))

      assign(socket, :staged_guests, Enum.take(staged ++ additions, room(existing)))
    end) || socket
  end

  @doc "Takes an address back off the list before it is sent."
  @spec unstage(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def unstage(socket, email) do
    assign(socket, :staged_guests, List.delete(staged(socket), email))
  end

  @doc "How many more guests a meeting with `existing` guests can take."
  @spec room([map()]) :: non_neg_integer()
  def room(existing), do: max(Guests.max_guests() - length(existing), 0)

  defp staged(socket), do: Map.get(socket.assigns, :staged_guests) || []
  defp existing(socket), do: Map.get(socket.assigns, :add_guests_existing) || []

  @doc """
  Handles the dialog's submission: closes it, invites, and reloads the list so
  the card shows the new guests.

  A duplicate submit — a double click, or Enter twice before the button
  disables — finds the modal data already cleared and does nothing, which is
  `ModalHook.with_modal_data/3`'s guarantee.
  """
  @spec confirm(Phoenix.LiveView.Socket.t(), (Phoenix.LiveView.Socket.t() ->
                                                Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def confirm(socket, reload) when is_function(reload, 1) do
    ModalHook.with_modal_data(socket, :add_guests, fn meeting ->
      staged = staged(socket)

      socket
      |> ModalHook.hide_modal(:add_guests)
      |> assign(:staged_guests, [])
      |> assign(:add_guests_existing, [])
      |> invite(meeting, staged)
      |> reload.()
    end) || socket
  end

  @doc """
  Adds `raw_emails` to `meeting` and schedules the invitations.

  Returns the socket with a flash describing what happened. Nothing is sent
  synchronously: the email job does the work, so a slow mail server cannot
  hold up the dashboard.
  """
  @spec invite(Phoenix.LiveView.Socket.t(), map(), [String.t()]) ::
          Phoenix.LiveView.Socket.t()
  def invite(socket, meeting, candidates) do
    case Guests.add_to_meeting(meeting.id, candidates, meeting.attendee_email) do
      {:ok, []} ->
        Flash.info(nothing_added_message(candidates))
        socket

      {:ok, added} ->
        MeetingScheduler.schedule_guest_invitations(meeting.id)

        Logger.info("Guests added to meeting",
          meeting_id: meeting.id,
          added: length(added)
        )

        Flash.info(
          dngettext(
            "dashboard_bookings",
            "Guest invited.",
            "%{count} guests invited.",
            length(added)
          )
        )

        socket

      {:error, :full} ->
        Flash.error(
          dgettext(
            "dashboard_bookings",
            "This meeting already has the maximum of %{count} guests.",
            count: Guests.max_guests()
          )
        )

        socket

      {:error, reason} ->
        Logger.error("Adding guests failed",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        Flash.error(dgettext("dashboard_bookings", "Those guests could not be added."))
        socket
    end
  end

  # An empty result is not a failure: either nothing was a usable address, or
  # every address was already on the meeting. Saying which is the difference
  # between "check the spelling" and "they already have it".
  defp nothing_added_message([]) do
    dgettext("dashboard_bookings", "Enter at least one email address.")
  end

  defp nothing_added_message(_candidates) do
    dgettext("dashboard_bookings", "Those addresses are already invited, or are not valid.")
  end
end
