defmodule TymeslotWeb.Themes.Shared.PaymentReturn do
  @moduledoc """
  Authorisation and lookup for the post-Stripe-Checkout return pages.

  `Shared.PaymentReturnLive.Processing` and `.Cancelled` serve
  `/themes/<slug>/payment-processing/<id>` and `/themes/<slug>/payment-cancelled/<id>`
  for every theme; this module holds their cross-cutting checks (theme slug,
  meeting lookup, theme match, session id match) so the LiveViews stay
  focused on rendering.

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
  alias Tymeslot.Demo
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations
  alias TymeslotWeb.Themes.Core.Registry, as: ThemeRegistry
  alias TymeslotWeb.Themes.Shared.EventHandlers
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
  defp authorize(meeting_id, theme_slug, session_id) do
    with {:ok, meeting, profile} <- organizer(meeting_id, theme_slug),
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
          {:ok,
           %{
             meeting: Tymeslot.Meetings.MeetingSchema.t(),
             profile: Tymeslot.Profiles.ProfileSchema.t(),
             rebook_path: String.t()
           }}
          | {:error, atom()}
  def lookup_for_cancel(meeting_id, theme_slug) do
    with {:ok, meeting, profile} <- organizer(meeting_id, theme_slug) do
      {:ok, %{meeting: meeting, profile: profile, rebook_path: rebook_path(profile, meeting)}}
    end
  end

  @doc """
  Assigns the organiser's customisation for the page's theme, as the booking
  page loads it (`Customization.Helpers.assign_theme_customization/3`):
  `:theme_tokens`, the `%Tokens{}` the theme's spec builds from the saved
  customisation or from its defaults, and `:theme_customized`, whether the
  organiser saved one. A theme with a `page_shell:` hands the tokens to its
  shell; Quill and Rhythm, whose own payment cards never showed the booking
  page's defaults, write them only when `:theme_customized` is true.

  Called on the connected mount, once the meeting's organiser is known: the
  dead render reads no data, so it has no customisation
  (`no_customization/1`).
  """
  @spec assign_customization(LiveView.Socket.t(), Tymeslot.Profiles.ProfileSchema.t()) ::
          LiveView.Socket.t()
  def assign_customization(socket, profile) do
    theme_id = socket.assigns.theme_id
    customization = Demo.get_theme_customization(profile.id, theme_id)

    Component.assign(socket,
      theme_tokens: ThemeCustomizations.tokens(theme_id, customization),
      theme_customized: customization != nil
    )
  end

  @doc "Assigns no customisation: the dead render's, before any data is read."
  @spec no_customization(LiveView.Socket.t()) :: LiveView.Socket.t()
  def no_customization(socket),
    do: Component.assign(socket, theme_tokens: nil, theme_customized: false)

  @doc """
  Assigns the language switcher's state: `:language_dropdown_open`, which a
  theme shell needs to draw the switcher, and the page's own address (its
  `path` and the `query` it must keep, such as `session_id`), which a locale
  change redirects back to (`build_path_with_locale/2`). Both renders get
  it, so the switcher is there from the first paint.
  """
  @spec assign_language_switcher(LiveView.Socket.t(), String.t(), map()) :: LiveView.Socket.t()
  def assign_language_switcher(socket, path, query) do
    Component.assign(socket, language_dropdown_open: false, locale_return: {path, query})
  end

  @doc """
  The language switcher's events (`toggle_language_dropdown`,
  `close_language_dropdown`, `change_locale`), as the booking pages handle
  them (`EventHandlers`): a locale change is a full redirect to this page.
  """
  @spec handle_language_event(String.t(), map(), LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_language_event("toggle_language_dropdown", _params, socket),
    do: EventHandlers.handle_toggle_language_dropdown(socket)

  def handle_language_event("close_language_dropdown", _params, socket),
    do: EventHandlers.handle_close_language_dropdown(socket)

  def handle_language_event("change_locale", %{"locale" => locale}, socket),
    do: EventHandlers.handle_change_locale(socket, locale, __MODULE__)

  def handle_language_event(_event, _params, socket), do: {:noreply, socket}

  @doc "This page's address with `?locale=` set, for a locale change's redirect."
  @spec build_path_with_locale(LiveView.Socket.t(), String.t()) :: String.t()
  def build_path_with_locale(socket, locale) do
    {path, query} = socket.assigns.locale_return
    path <> "?" <> URI.encode_query(Map.put(query, "locale", locale))
  end

  @doc "A page's path from its URL segments, each escaped."
  @spec page_path(String.t(), String.t(), String.t()) :: String.t()
  def page_path(theme_slug, page, meeting_id) do
    "/" <> Enum.map_join(["themes", theme_slug, page, meeting_id], "/", &escape_segment/1)
  end

  defp escape_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

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
  Resolves the URL's theme slug and assigns `:theme_id` and `:theme_module`.

  The scheduling root layout reads `:theme_id` to choose the theme's
  stylesheet and class, so this runs on the dead render too, before any data
  is read. An unknown slug is `{:error, :unknown_theme}`.
  """
  @spec assign_theme(LiveView.Socket.t(), String.t()) ::
          {:ok, LiveView.Socket.t()} | {:error, :unknown_theme}
  def assign_theme(socket, slug) do
    case ThemeRegistry.get_theme_by_slug(slug) do
      {:ok, theme} ->
        {:ok, Component.assign(socket, theme_id: theme.id, theme_module: theme.module)}

      {:error, :theme_not_found} ->
        {:error, :unknown_theme}
    end
  end

  @doc """
  Sends the attendee home with a generic flash, so the page never reveals
  which check failed.
  """
  @spec reject(LiveView.Socket.t()) :: LiveView.Socket.t()
  def reject(socket) do
    socket
    |> LiveView.put_flash(:error, dgettext("booking", "Payment not found."))
    |> LiveView.redirect(to: "/")
  end

  @doc """
  Mounts the payment-processing page. Authorises the meeting,
  subscribes to the payment topic, then reads meeting/payment state and
  assigns `:meeting`, `:payment`, `:rebook_path` (where a failed checkout
  can start again) and the organiser's customisation (`assign_customization/2`)
  on success. On failure the socket is
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
    socket =
      assign_language_switcher(
        socket,
        page_path(theme_slug, "payment-processing", meeting_id),
        Map.take(params, ["session_id"])
      )

    if LiveView.connected?(socket) do
      PubSub.subscribe(Tymeslot.PubSub, topic(meeting_id))

      case authorize(meeting_id, theme_slug, params["session_id"]) do
        {:ok, %{meeting: meeting, payment: payment, profile: profile}} ->
          socket =
            socket
            |> assign_customization(profile)
            |> Component.assign(
              loading: false,
              meeting: meeting,
              payment: payment,
              rebook_path: rebook_path(profile, meeting)
            )

          {:ok, socket}

        {:error, _reason} ->
          {:ok, reject(socket)}
      end
    else
      socket =
        socket
        |> no_customization()
        |> Component.assign(loading: true, meeting: nil, payment: nil, rebook_path: nil)

      {:ok, socket}
    end
  end

  @doc """
  Re-reads the meeting and its payment after a PubSub broadcast on the
  payment topic (`:paid` from `CheckoutSessionCompleted`, `:expired` from
  `FailAndExpire`), so the page renders what the webhook actually wrote.

  Re-fetches the meeting, not just the payment: paid does not always mean
  confirmed (a paid, approval-gated booking moves to `"awaiting_approval"`),
  and a failed checkout expires the meeting rather than the payment alone.
  """
  @spec refresh(LiveView.Socket.t()) :: LiveView.Socket.t()
  def refresh(socket) do
    payment = MeetingPayments.payment_for_meeting(socket.assigns.meeting.id)

    socket =
      case Meetings.get_meeting(socket.assigns.meeting.id) do
        {:ok, meeting} -> Component.assign(socket, :meeting, meeting)
        {:error, :not_found} -> socket
      end

    Component.assign(socket, :payment, payment)
  end

  @typedoc "What the return page should tell the attendee right now."
  @type outcome ::
          :loading
          | :failed
          | :awaiting_approval
          | :declined
          | :expired
          | :confirmed
          | :cancelled

  @doc """
  Classifies the return page's state for a themed `render/1` `case`.

  The booking outcome is the domain's (`MeetingPayments.checkout_outcome/2`);
  this only adds `:loading` for the disconnected render and shows a checkout
  still being processed the same way.
  """
  @spec outcome(loading :: boolean(), MeetingPayments.booking_payment() | nil, Meeting.t() | nil) ::
          outcome()
  def outcome(true, _payment, _meeting), do: :loading

  def outcome(false, payment, meeting) do
    case MeetingPayments.checkout_outcome(payment, meeting) do
      :processing -> :loading
      outcome -> outcome
    end
  end

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

  defp organizer(meeting_id, theme_slug) do
    with {:ok, meeting} <- get_meeting(meeting_id),
         {:ok, profile} <- get_profile(meeting),
         :ok <- validate_theme(profile, theme_slug) do
      {:ok, meeting, profile}
    end
  end

  defp get_meeting(id) do
    case Meetings.get_meeting(id) do
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
