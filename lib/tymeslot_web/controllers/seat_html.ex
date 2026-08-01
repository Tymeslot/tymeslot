defmodule TymeslotWeb.SeatHTML do
  @moduledoc """
  Renders the public seat-management pages for group-booking participants:
  cancel confirmation landing, cancelled, not-allowed, and error states.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Helpers.MeetingTimeFormat

  @doc "Landing page shown before the participant confirms the cancellation (GET step)."
  attr :participant, :map, required: true
  attr :meeting, :map, required: true
  attr :token, :string, required: true

  @spec cancel_confirm(map()) :: Phoenix.LiveView.Rendered.t()
  def cancel_confirm(assigns) do
    ~H"""
    <.seat_shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-amber-100 text-amber-600">
        <.icon name="hero-x-circle" class="h-9 w-9" />
      </div>

      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking", "Cancel your spot?")}
      </h1>

      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext("booking", "Confirm to give up your spot in this meeting with %{name}.",
          name: @meeting.organizer_name
        )}
      </p>

      <.meeting_card meeting={@meeting} timezone={@participant.timezone} />

      <form method="post" action={"/seat/#{@token}/cancel"} class="mt-6">
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <button
          type="submit"
          class="w-full rounded-token-xl bg-amber-500 px-6 py-3 text-token-base font-semibold text-white hover:bg-amber-600"
        >
          {dgettext("booking", "Yes, cancel my spot")}
        </button>
      </form>
    </.seat_shell>
    """
  end

  @doc "Shown after the participant's seat has been cancelled."
  attr :participant, :map, required: true
  attr :meeting, :map, required: true

  @spec cancelled(map()) :: Phoenix.LiveView.Rendered.t()
  def cancelled(assigns) do
    ~H"""
    <.seat_shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-green-100 text-green-600">
        <.icon name="hero-check-circle" class="h-9 w-9" />
      </div>

      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking", "Your spot has been cancelled")}
      </h1>

      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext("booking", "We've let %{name} know. A confirmation email is on its way.",
          name: @meeting.organizer_name
        )}
      </p>

      <.meeting_card meeting={@meeting} timezone={@participant.timezone} />
    </.seat_shell>
    """
  end

  @doc "Shown when policy refuses the cancellation (e.g. too close to start)."
  @spec not_allowed(map()) :: Phoenix.LiveView.Rendered.t()
  def not_allowed(assigns) do
    ~H"""
    <.seat_shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-amber-100 text-amber-600">
        <.icon name="hero-clock" class="h-9 w-9" />
      </div>
      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking", "This spot can no longer be cancelled online")}
      </h1>
      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext(
          "booking",
          "The meeting is too close to its start time. Please contact the host directly."
        )}
      </p>
    </.seat_shell>
    """
  end

  @doc "Shown when the seat token is missing, invalid, or already used up."
  @spec invalid(map()) :: Phoenix.LiveView.Rendered.t()
  def invalid(assigns) do
    ~H"""
    <.seat_shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-tymeslot-100 text-tymeslot-500">
        <.icon name="hero-link-slash" class="h-9 w-9" />
      </div>
      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking", "This link is no longer valid")}
      </h1>
      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext(
          "booking",
          "The link may have expired or already been used. Please contact the meeting host."
        )}
      </p>
    </.seat_shell>
    """
  end

  @doc "Shown when the participant has made too many requests in a short window."
  @spec too_many_requests(map()) :: Phoenix.LiveView.Rendered.t()
  def too_many_requests(assigns) do
    ~H"""
    <.seat_shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-amber-100 text-amber-600">
        <.icon name="hero-clock" class="h-9 w-9" />
      </div>
      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking", "Too many attempts")}
      </h1>
      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext("booking", "Please wait a moment and try again.")}
      </p>
    </.seat_shell>
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
        {dgettext("booking", "Hosted by %{name}", name: @meeting.organizer_name)}
      </p>
    </div>
    """
  end

  # Shared centred-card page chrome (same shell as the guest RSVP pages).
  slot :inner_block, required: true

  defp seat_shell(assigns) do
    ~H"""
    <main class="flex min-h-screen items-center justify-center bg-linear-to-br from-turquoise-50 via-white to-cyan-50 p-4">
      <div class="w-full max-w-md rounded-token-2xl bg-white p-8 text-center shadow-glass-lg">
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end
end
