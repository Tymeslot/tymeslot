defmodule TymeslotWeb.SeatHTML do
  @moduledoc """
  Renders the public seat-management pages for group-booking participants:
  cancel confirmation landing, cancelled, not-allowed, and error states.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Shared.TokenPage
  alias TymeslotWeb.Helpers.MeetingTimeFormat

  @doc "Landing page shown before the participant confirms the cancellation (GET step)."
  attr :participant, :map, required: true
  attr :meeting, :map, required: true
  attr :token, :string, required: true
  attr :keep_path, :string, default: nil

  @spec cancel_confirm(map()) :: Phoenix.LiveView.Rendered.t()
  def cancel_confirm(assigns) do
    ~H"""
    <TokenPage.shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-amber-100 text-amber-600">
        <.icon name="hero-x-circle" class="h-9 w-9" />
      </div>

      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking_manage", "Cancel your spot?")}
      </h1>

      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext("booking_manage", "Confirm to give up your spot in this meeting with %{name}.",
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
          {dgettext("booking_manage", "Yes, cancel my spot")}
        </button>
      </form>

      <%!-- An escape hatch: arriving here by accident should not leave
           closing the tab as the only way out. --%>
      <a
        :if={@keep_path}
        href={@keep_path}
        class="mt-4 inline-block text-token-sm font-semibold text-tymeslot-500 hover:text-turquoise-600"
      >
        {dgettext("booking_manage", "Keep my spot")}
      </a>
    </TokenPage.shell>
    """
  end

  @doc "Shown after the participant's seat has been cancelled."
  attr :participant, :map, required: true
  attr :meeting, :map, required: true
  attr :booking_path, :string, default: nil

  @spec cancelled(map()) :: Phoenix.LiveView.Rendered.t()
  def cancelled(assigns) do
    ~H"""
    <TokenPage.shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-green-100 text-green-600">
        <.icon name="hero-check-circle" class="h-9 w-9" />
      </div>

      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking_manage", "Your spot has been cancelled")}
      </h1>

      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext("booking_manage", "We've let %{name} know. A confirmation email is on its way.",
          name: @meeting.organizer_name
        )}
      </p>

      <.meeting_card meeting={@meeting} timezone={@participant.timezone} />

      <a
        :if={@booking_path}
        href={@booking_path}
        class="mt-6 inline-block text-token-sm font-semibold text-turquoise-600 hover:text-turquoise-700"
      >
        {dgettext("booking_manage", "Book another time")}
      </a>
    </TokenPage.shell>
    """
  end

  @doc "Shown when policy refuses the cancellation (e.g. too close to start)."
  @spec not_allowed(map()) :: Phoenix.LiveView.Rendered.t()
  def not_allowed(assigns) do
    ~H"""
    <TokenPage.shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-amber-100 text-amber-600">
        <.icon name="hero-clock" class="h-9 w-9" />
      </div>
      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking_manage", "This spot can no longer be cancelled online")}
      </h1>
      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext(
          "booking_manage",
          "The meeting is too close to its start time. Please contact the host directly."
        )}
      </p>
    </TokenPage.shell>
    """
  end

  @doc "Shown when the token is missing, invalid, or already used up."
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
