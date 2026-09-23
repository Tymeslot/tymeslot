defmodule TymeslotWeb.GuestRsvpHTML do
  @moduledoc """
  Renders the public guest-RSVP pages: pre-confirmation landing, success, and error states.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Helpers.LocaleFormat

  @doc "Landing page shown before the guest submits their RSVP (GET step)."
  attr :meeting, :map, required: true
  attr :status, :string, required: true
  attr :token, :string, required: true
  attr :response, :string, required: true

  @spec confirm(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm(assigns) do
    ~H"""
    <% accepting? = @status == "accepted" %>
    <.rsvp_shell>
      <.rsvp_badge accepted?={accepting?} />

      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {if accepting?,
          do: dgettext("booking", "You're about to accept"),
          else: dgettext("booking", "You're about to decline")}
      </h1>

      <p class="mt-2 text-token-base text-tymeslot-600">
        {if accepting? do
          dgettext("booking", "Confirm to let %{name} know you'll be attending.",
            name: @meeting.organizer_name
          )
        else
          dgettext("booking", "Confirm to let %{name} know you can't make it.",
            name: @meeting.organizer_name
          )
        end}
      </p>

      <.meeting_summary meeting={@meeting} />

      <.form for={%{}} action={~p"/guest/#{@token}/#{@response}"} class="mt-6">
        <.action_button
          type="submit"
          variant={if accepting?, do: :primary, else: :secondary}
          class="w-full"
        >
          {if accepting?,
            do: dgettext("booking", "Confirm attendance"),
            else: dgettext("booking", "Confirm decline")}
        </.action_button>
      </.form>
    </.rsvp_shell>
    """
  end

  @doc "Shown after a guest successfully accepts or declines their invitation."
  attr :meeting, :map, required: true
  attr :status, :string, required: true
  attr :token, :string, required: true

  @spec confirmation(map()) :: Phoenix.LiveView.Rendered.t()
  def confirmation(assigns) do
    ~H"""
    <% accepted? = @status == "accepted" %>
    <.rsvp_shell>
      <.rsvp_badge accepted?={accepted?} />

      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {if accepted?,
          do: dgettext("booking", "You're going!"),
          else: dgettext("booking", "You've declined")}
      </h1>

      <p class="mt-2 text-token-base text-tymeslot-600">
        {if accepted? do
          dgettext("booking", "Your response has been sent to %{name}.",
            name: @meeting.organizer_name
          )
        else
          dgettext("booking", "We've let %{name} know you can't make it.",
            name: @meeting.organizer_name
          )
        end}
      </p>

      <.meeting_summary meeting={@meeting} />

      <p class="mt-6 text-token-sm text-tymeslot-500">
        {if accepted?,
          do: dgettext("booking", "Changed your mind?"),
          else: dgettext("booking", "Able to make it after all?")}
        <.link
          href={~p"/guest/#{@token}/#{if accepted?, do: "decline", else: "accept"}"}
          class="font-medium text-turquoise-600 underline"
        >
          {if accepted?,
            do: dgettext("booking", "Decline instead"),
            else: dgettext("booking", "Accept instead")}
        </.link>
      </p>
    </.rsvp_shell>
    """
  end

  @doc "Shown when the meeting behind a valid link no longer takes responses."
  @spec closed(map()) :: Phoenix.LiveView.Rendered.t()
  def closed(assigns) do
    ~H"""
    <.rsvp_shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-tymeslot-100 text-tymeslot-500">
        <.icon name="hero-calendar-days" class="h-9 w-9" />
      </div>
      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking", "This meeting is no longer taking responses")}
      </h1>
      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext(
          "booking",
          "The meeting has already taken place, or it was cancelled or not confirmed. Please contact the meeting host."
        )}
      </p>
    </.rsvp_shell>
    """
  end

  @doc "Shown when the RSVP token is missing or invalid."
  @spec invalid(map()) :: Phoenix.LiveView.Rendered.t()
  def invalid(assigns) do
    ~H"""
    <.rsvp_shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-tymeslot-100 text-tymeslot-500">
        <.icon name="hero-link-slash" class="h-9 w-9" />
      </div>
      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking", "This link is not valid")}
      </h1>
      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext(
          "booking",
          "We couldn't find an invitation for this link. Please check that you copied the whole link from your email, or contact the meeting host."
        )}
      </p>
    </.rsvp_shell>
    """
  end

  @doc "Shown when the guest has made too many requests in a short window."
  @spec too_many_requests(map()) :: Phoenix.LiveView.Rendered.t()
  def too_many_requests(assigns) do
    ~H"""
    <.rsvp_shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-amber-100 text-amber-600">
        <.icon name="hero-clock" class="h-9 w-9" />
      </div>
      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking", "Too many attempts")}
      </h1>
      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext("booking", "Please wait a moment and try again.")}
      </p>
    </.rsvp_shell>
    """
  end

  # Shared centred-card page chrome.
  slot :inner_block, required: true

  defp rsvp_shell(assigns) do
    ~H"""
    <main class="flex min-h-screen items-center justify-center bg-linear-to-br from-turquoise-50 via-white to-cyan-50 p-4">
      <div class="w-full max-w-md rounded-token-2xl bg-white p-8 text-center shadow-glass-lg">
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end

  # Status icon: a tick for accepting, a cross for declining.
  attr :accepted?, :boolean, required: true

  defp rsvp_badge(assigns) do
    ~H"""
    <div class={[
      "mx-auto flex h-16 w-16 items-center justify-center rounded-token-full",
      @accepted? && "bg-green-100 text-green-600",
      !@accepted? && "bg-amber-100 text-amber-600"
    ]}>
      <.icon name={if @accepted?, do: "hero-check-circle", else: "hero-x-circle"} class="h-9 w-9" />
    </div>
    """
  end

  # The meeting's title, time and host.
  attr :meeting, :map, required: true

  defp meeting_summary(assigns) do
    ~H"""
    <div class="mt-6 space-y-2 rounded-token-xl bg-tymeslot-50 p-5 text-left">
      <p class="text-token-base font-semibold text-tymeslot-800">{@meeting.title}</p>
      <p class="flex items-center gap-2 text-token-sm text-tymeslot-600">
        <.icon name="hero-calendar-mini" class="h-4 w-4 text-turquoise-500" />
        {format_when(@meeting)}
      </p>
      <p class="flex items-center gap-2 text-token-sm text-tymeslot-600">
        <.icon name="hero-user-mini" class="h-4 w-4 text-turquoise-500" />
        {dgettext("booking", "Hosted by %{name}", name: @meeting.organizer_name)}
      </p>
    </div>
    """
  end

  defp format_when(meeting) do
    tz = meeting.attendee_timezone || "Etc/UTC"

    locale = Gettext.get_locale(TymeslotWeb.Gettext)

    case DateTime.shift_zone(meeting.start_time, tz) do
      {:ok, dt} -> LocaleFormat.format_weekday_datetime(dt, locale) <> " (#{tz})"
      _error -> LocaleFormat.format_weekday_datetime(meeting.start_time, locale) <> " UTC"
    end
  end
end
