defmodule TymeslotWeb.Themes.Shared.PaymentReturn do
  @moduledoc """
  Authorisation/lookup helpers for the post-Stripe-Checkout return pages.

  Each theme exposes its own LiveView for `/themes/<slug>/payment-processing/<id>`
  and `/themes/<slug>/payment-cancelled/<id>`; this module shares the
  cross-cutting checks (meeting lookup, theme match, session id match) so
  the theme LiveViews can stay focused on rendering.

  Returns `{:ok, %{meeting:, payment:, profile:}}` only when:

    * the meeting exists,
    * the host's profile booking_theme matches the URL slug (host can't
      be tricked into sending attendees down the wrong theme),
    * a `booking_payment` row for the meeting exists,
    * the `session_id` query param matches the stored
      `stripe_checkout_session_id` (prevents cross-meeting probing).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Phoenix.PubSub
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Core.Registry, as: ThemeRegistry
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @type ctx :: %{
          meeting: Tymeslot.Meetings.MeetingSchema.t(),
          payment: MeetingPayments.booking_payment(),
          profile: Tymeslot.Profiles.ProfileSchema.t()
        }

  @spec authorize(
          meeting_id :: String.t(),
          theme_slug :: String.t(),
          session_id :: String.t() | nil
        ) :: {:ok, ctx()} | {:error, atom()}
  def authorize(meeting_id, theme_slug, session_id) do
    with {:ok, meeting} <- get_meeting(meeting_id),
         {:ok, profile} <- get_profile(meeting),
         :ok <- validate_theme(profile, theme_slug),
         {:ok, payment} <- get_payment(meeting_id),
         :ok <- validate_session(session_id, payment) do
      {:ok, %{meeting: meeting, payment: payment, profile: profile}}
    end
  end

  @doc """
  Resolves a meeting + rebook path for the cancellation page (no session_id
  match — the attendee may arrive here from any state, including
  before checkout completed).

  `rebook_path` points back to the meeting type's booking page so the
  attendee can try again, falling back to the host's overview page (or `/`
  when the host has no public username).
  """
  @spec lookup_for_cancel(meeting_id :: String.t(), theme_slug :: String.t()) ::
          {:ok, %{meeting: Tymeslot.Meetings.MeetingSchema.t(), rebook_path: String.t()}}
          | {:error, atom()}
  def lookup_for_cancel(meeting_id, theme_slug) do
    with {:ok, meeting} <- get_meeting(meeting_id),
         {:ok, profile} <- get_profile(meeting),
         :ok <- validate_theme(profile, theme_slug) do
      {:ok, %{meeting: meeting, rebook_path: rebook_path(profile, meeting)}}
    end
  end

  defp rebook_path(%{username: username}, meeting)
       when is_binary(username) and username != "" do
    case meeting_type_slug(meeting) do
      nil -> "/" <> username
      slug -> "/" <> username <> "/" <> slug
    end
  end

  defp rebook_path(_profile, _meeting), do: "/"

  defp meeting_type_slug(%{meeting_type_id: id, organizer_user_id: user_id})
       when is_integer(id) and is_integer(user_id) do
    case MeetingTypes.get_meeting_type(id, user_id) do
      %{} = meeting_type -> MeetingTypes.effective_slug(meeting_type)
      _missing -> nil
    end
  end

  defp meeting_type_slug(_meeting), do: nil

  @doc """
  Stable PubSub topic for payment status broadcasts on a given meeting.
  """
  @spec topic(String.t()) :: String.t()
  def topic(meeting_id), do: "meeting_payment:#{meeting_id}"

  @doc """
  Mounts a per-theme payment-processing LiveView. Authorises the meeting,
  subscribes to the payment topic, then reads meeting/payment state and
  assigns `:meeting` and `:payment` on success. On failure the socket is
  redirected to `/` with a generic flash so we never leak the failure mode
  to the attendee.

  Subscribes *before* reading state, not after: a `:paid` (or `:expired`)
  broadcast that lands between the read and the subscribe would otherwise
  never reach this process, leaving the page showing stale state with no
  further message to correct it.
  """
  @spec mount_payment_processing(
          params :: map(),
          socket :: LiveView.Socket.t(),
          theme_slug :: String.t()
        ) :: {:ok, LiveView.Socket.t()}
  def mount_payment_processing(%{"meeting_id" => meeting_id} = params, socket, theme_slug) do
    if LiveView.connected?(socket) do
      PubSub.subscribe(Tymeslot.PubSub, topic(meeting_id))

      case authorize(meeting_id, theme_slug, params["session_id"]) do
        {:ok, %{meeting: meeting, payment: payment}} ->
          socket =
            socket
            |> Component.assign(:loading, false)
            |> Component.assign(:meeting, meeting)
            |> Component.assign(:payment, payment)

          {:ok, socket}

        {:error, _reason} ->
          socket =
            socket
            |> LiveView.put_flash(:error, dgettext("booking", "Payment not found."))
            |> LiveView.redirect(to: "/")

          {:ok, socket}
      end
    else
      {:ok, Component.assign(socket, loading: true, meeting: nil, payment: nil)}
    end
  end

  @doc """
  Handles the `:paid` PubSub message common to every theme's payment
  processing LiveView.

  Paid does not always mean confirmed: a meeting type can be both paid and
  approval-gated, in which case the webhook moves the meeting to
  `"awaiting_approval"` rather than `"confirmed"`
  (`CheckoutSessionCompleted.post_payment_status/1`). Re-fetches the
  meeting, not just the payment, so the page reads that status rather than
  assuming a successful payment finished the booking.
  """
  @spec refresh_after_paid(LiveView.Socket.t()) :: LiveView.Socket.t()
  def refresh_after_paid(socket) do
    payment = MeetingPayments.payment_for_meeting(socket.assigns.meeting.id)

    socket =
      case MeetingQueries.get_meeting(socket.assigns.meeting.id) do
        {:ok, meeting} -> Component.assign(socket, :meeting, meeting)
        {:error, :not_found} -> socket
      end

    Component.assign(socket, :payment, payment)
  end

  @typedoc "What the return page should tell the attendee right now."
  @type outcome :: :loading | :awaiting_approval | :declined | :expired | :confirmed

  @doc """
  Classifies the return page's state for a themed `render/1` `case`.

  Order matters, and it is not the render's original `cond` order: a
  resolved gate outcome (`:declined`, `:expired`) is checked *before* the
  raw payment status, because `Approval.release/3` refunds the held
  request in full, which flips `payment.status` away from `"paid"` — a
  status-first check would send a declined or expired paid booking back
  through `:loading` instead of telling the attendee what happened.
  `payment.paid_at` (rather than `payment.status`) is what proves this
  checkout's payment cycle ever completed, since it survives that same
  refund. `Approval.declined?/1` and the `"expired"` status are what prove
  `:declined`/`:expired` specifically came from the approval gate
  (`Approval.decline/2`, `Approval.expire/1`), as opposed to an ordinary
  cancellation with no refund guarantee. `approval_resolved_at` cannot prove
  it: `Approval.approve/1` stamps that too, so a paid meeting the host
  approved and then cancelled would have been reported to the attendee as
  declined.
  """
  @spec outcome(loading :: boolean(), MeetingPayments.booking_payment() | nil, Meeting.t() | nil) ::
          outcome()
  def outcome(true, _payment, _meeting), do: :loading

  def outcome(false, %{paid_at: %DateTime{}}, %{
        status: "expired",
        approval_resolved_at: %DateTime{}
      }),
      do: :expired

  def outcome(false, %{paid_at: %DateTime{}}, %Meeting{} = meeting) do
    cond do
      Approval.declined?(meeting) -> :declined
      MeetingState.awaiting_approval?(meeting) -> :awaiting_approval
      true -> :confirmed
    end
  end

  def outcome(false, _payment, _meeting), do: :loading

  @doc """
  Formats a gated meeting's approval deadline for the return page, or
  `nil` when there is none to show (an unpaid/ungated meeting, or one
  where the deadline field has not been backfilled).
  """
  @spec approval_deadline_text(Meeting.t()) :: String.t() | nil
  def approval_deadline_text(%{approval_deadline_at: %DateTime{}} = meeting) do
    LocalizationHelpers.format_meeting_datetime(
      meeting.approval_deadline_at,
      meeting.attendee_timezone
    )
  end

  def approval_deadline_text(_meeting), do: nil

  defp get_meeting(id) do
    case MeetingQueries.get_meeting(id) do
      {:ok, meeting} -> {:ok, meeting}
      {:error, :not_found} -> {:error, :meeting_not_found}
    end
  end

  defp get_profile(meeting) do
    case Profiles.get_profile(meeting.organizer_user_id) do
      nil -> {:error, :profile_not_found}
      profile -> {:ok, profile}
    end
  end

  defp validate_theme(profile, slug) do
    case ThemeRegistry.id_to_key(profile.booking_theme || ThemeRegistry.default_theme_id()) do
      {:ok, key} ->
        if Atom.to_string(key) == slug, do: :ok, else: {:error, :wrong_theme}

      {:error, :invalid_theme_id} ->
        {:error, :wrong_theme}
    end
  end

  defp get_payment(meeting_id) do
    case MeetingPayments.payment_for_meeting(meeting_id) do
      nil -> {:error, :payment_not_found}
      payment -> {:ok, payment}
    end
  end

  defp validate_session(nil, _payment), do: {:error, :missing_session}

  defp validate_session(provided, %{stripe_checkout_session_id: stored})
       when is_binary(stored) do
    if provided == stored, do: :ok, else: {:error, :session_mismatch}
  end

  defp validate_session(_provided, _payment), do: {:error, :session_mismatch}
end
