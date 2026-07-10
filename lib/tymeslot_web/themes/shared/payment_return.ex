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
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Core.Registry, as: ThemeRegistry

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
  subscribes to the payment topic on connect, and assigns `:meeting` and
  `:payment` on success. On failure the socket is redirected to `/` with
  a generic flash so we never leak the failure mode to the attendee.
  """
  @spec mount_payment_processing(
          params :: map(),
          socket :: LiveView.Socket.t(),
          theme_slug :: String.t()
        ) :: {:ok, LiveView.Socket.t()}
  def mount_payment_processing(%{"meeting_id" => meeting_id} = params, socket, theme_slug) do
    if LiveView.connected?(socket) do
      case authorize(meeting_id, theme_slug, params["session_id"]) do
        {:ok, %{meeting: meeting, payment: payment}} ->
          PubSub.subscribe(Tymeslot.PubSub, topic(meeting.id))

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
