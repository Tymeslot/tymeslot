defmodule TymeslotWeb.SeatHTML do
  @moduledoc """
  Renders the public seat-management pages for group-booking participants:
  the cancel confirmation landing, the cancelled page, and the pages for a
  link that can no longer be used (seat already given up, meeting cancelled
  by the host, meeting under way or over, spot that cannot be moved, unknown
  link).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Shared.TokenPage
  alias TymeslotWeb.Helpers.MeetingTimeFormat
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage

  @doc "Landing page shown before the participant confirms the cancellation (GET step)."
  attr :participant, :map, required: true
  attr :meeting, :map, required: true
  attr :token, :string, required: true
  attr :keep_path, :string, default: nil

  @spec cancel_confirm(map()) :: Phoenix.LiveView.Rendered.t()
  def cancel_confirm(assigns) do
    ~H"""
    <TokenPage.shell>
      <.status_icon name="hero-x-circle" tone={:warning} />

      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking_manage", "Cancel your spot?")}
      </h1>

      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext("booking_manage", "Confirm to give up your spot in this meeting with %{name}.",
          name: @meeting.organizer_name
        )}
      </p>

      <.meeting_card meeting={@meeting} timezone={@participant.timezone} />

      <.form for={%{}} action={~p"/seat/#{@token}/cancel"} class="mt-6">
        <.action_button type="submit" variant={:danger} class="w-full">
          {dgettext("booking_manage", "Yes, cancel my spot")}
        </.action_button>
      </.form>

      <%!-- An escape hatch: arriving here by accident should not leave
           closing the tab as the only way out. --%>
      <.link
        :if={@keep_path}
        href={@keep_path}
        class="mt-4 inline-block text-token-sm font-medium text-turquoise-600 underline"
      >
        {dgettext("booking_manage", "Keep my spot")}
      </.link>
    </TokenPage.shell>
    """
  end

  @doc """
  Shown after this request cancelled the participant's seat, and only then:
  it is the one page that says the host was told and an email is on its way.
  """
  attr :participant, :map, required: true
  attr :meeting, :map, required: true
  attr :booking_path, :string, default: nil

  @spec cancelled(map()) :: Phoenix.LiveView.Rendered.t()
  def cancelled(assigns) do
    ~H"""
    <TokenPage.shell>
      <.status_icon name="hero-check-circle" tone={:success} />

      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking_manage", "Your spot has been cancelled")}
      </h1>

      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext("booking_manage", "We've let %{name} know. A confirmation email is on its way.",
          name: @meeting.organizer_name
        )}
      </p>

      <.meeting_card meeting={@meeting} timezone={@participant.timezone} />

      <.link
        :if={@booking_path}
        href={@booking_path}
        class="mt-6 inline-block text-token-sm font-medium text-turquoise-600 underline"
      >
        {dgettext("booking_manage", "Book another time")}
      </.link>
    </TokenPage.shell>
    """
  end

  @doc "Shown for a seat the participant already gave up or moved to another time."
  @spec already_cancelled(map()) :: Phoenix.LiveView.Rendered.t()
  def already_cancelled(assigns) do
    ~H"""
    <.notice
      icon="hero-check-circle"
      tone={:neutral}
      title={dgettext("booking_manage", "This spot is already cancelled")}
      body={
        dgettext(
          "booking_manage",
          "It was cancelled or moved to another time, so there is nothing left to do here. If you moved it, the email confirming your new time has links to manage it."
        )
      }
    />
    """
  end

  @doc "Shown for a seat on a meeting the host has cancelled."
  @spec meeting_cancelled(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_cancelled(assigns) do
    ~H"""
    <.notice
      icon="hero-calendar-days"
      tone={:neutral}
      title={dgettext("booking_manage", "This meeting has been cancelled")}
      body={
        dgettext(
          "booking_manage",
          "The host cancelled this meeting, so your spot no longer needs cancelling. Please contact the meeting host if you have any questions."
        )
      }
    />
    """
  end

  @doc """
  Shown when the meeting no longer lets a spot be given up: it is under way,
  it is over, or the policy refused for another reason.
  """
  attr :reason, :any, required: true

  @spec not_allowed(map()) :: Phoenix.LiveView.Rendered.t()
  def not_allowed(%{reason: :meeting_started} = assigns) do
    ~H"""
    <.notice
      icon="hero-clock"
      tone={:warning}
      title={dgettext("booking_manage", "This meeting has already started")}
      body={
        dgettext(
          "booking_manage",
          "Your spot can no longer be cancelled online. Please contact the host directly."
        )
      }
    />
    """
  end

  def not_allowed(%{reason: :meeting_past} = assigns) do
    ~H"""
    <.notice
      icon="hero-calendar-days"
      tone={:neutral}
      title={dgettext("booking_manage", "This meeting has already taken place")}
      body={dgettext("booking_manage", "There is no spot left to cancel.")}
    />
    """
  end

  def not_allowed(assigns) do
    ~H"""
    <.notice
      icon="hero-clock"
      tone={:warning}
      title={dgettext("booking_manage", "This spot can no longer be cancelled online")}
      body={dgettext("booking_manage", "Please contact the host directly.")}
    />
    """
  end

  @doc """
  Shown from the reschedule link when the meeting type stopped taking group
  bookings after the seat was booked: the seat stays, but cannot be moved.
  """
  attr :token, :string, required: true

  @spec not_movable(map()) :: Phoenix.LiveView.Rendered.t()
  def not_movable(assigns) do
    ~H"""
    <.notice
      icon="hero-arrows-right-left"
      tone={:warning}
      title={dgettext("booking_manage", "This spot can't be moved")}
      body={BookingErrorMessage.message(:seat_not_movable)}
    >
      <.link
        href={~p"/seat/#{@token}/cancel"}
        class="mt-6 inline-block text-token-sm font-medium text-turquoise-600 underline"
      >
        {dgettext("booking_manage", "Cancel my spot")}
      </.link>
    </.notice>
    """
  end

  @doc "Shown when the token is missing or invalid."
  @spec invalid(map()) :: Phoenix.LiveView.Rendered.t()
  def invalid(assigns) do
    ~H"""
    <TokenPage.invalid body={
      dgettext(
        "booking_manage",
        "The link may have expired or already been used. Please contact the meeting host."
      )
    } />
    """
  end

  @doc "Shown when the visitor has made too many requests in a short window."
  @spec too_many_requests(map()) :: Phoenix.LiveView.Rendered.t()
  def too_many_requests(assigns), do: TokenPage.too_many_requests(assigns)

  # A one-message page: icon, heading, explanation, and room for an action.
  attr :icon, :string, required: true
  attr :tone, :atom, values: [:success, :warning, :neutral], required: true
  attr :title, :string, required: true
  attr :body, :string, required: true
  slot :inner_block

  defp notice(assigns) do
    ~H"""
    <TokenPage.shell>
      <.status_icon name={@icon} tone={@tone} />
      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">{@title}</h1>
      <p class="mt-2 text-token-base text-tymeslot-600">{@body}</p>
      {render_slot(@inner_block)}
    </TokenPage.shell>
    """
  end

  attr :name, :string, required: true
  attr :tone, :atom, values: [:success, :warning, :neutral], required: true

  defp status_icon(assigns) do
    ~H"""
    <div class={[
      "mx-auto flex h-16 w-16 items-center justify-center rounded-token-full",
      @tone == :success && "bg-green-100 text-green-600",
      @tone == :warning && "bg-amber-100 text-amber-600",
      @tone == :neutral && "bg-tymeslot-100 text-tymeslot-500"
    ]}>
      <.icon name={@name} class="h-9 w-9" />
    </div>
    """
  end

  attr :meeting, :map, required: true
  attr :timezone, :string, default: nil

  defp meeting_card(assigns) do
    ~H"""
    <div class="mt-6 space-y-2 rounded-token-xl bg-tymeslot-50 p-5 text-left">
      <p class="text-token-base font-semibold text-tymeslot-800">{@meeting.title}</p>
      <p class="flex items-center gap-2 text-token-sm text-tymeslot-600">
        <.icon name="hero-calendar-mini" class="h-4 w-4 text-turquoise-500" />
        {MeetingTimeFormat.format_when(@meeting, @timezone)}
      </p>
      <p class="flex items-center gap-2 text-token-sm text-tymeslot-600">
        <.icon name="hero-user-mini" class="h-4 w-4 text-turquoise-500" />
        {dgettext("booking_manage", "Hosted by %{name}", name: @meeting.organizer_name)}
      </p>
    </div>
    """
  end
end
