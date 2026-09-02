defmodule TymeslotWeb.GuestRsvpHTML do
  @moduledoc """
  Renders the public guest-RSVP pages: pre-confirmation landing, success, and error states.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Shared.TokenPage
  alias TymeslotWeb.Helpers.MeetingTimeFormat

  @doc "Landing page shown before the guest submits their RSVP (GET step)."
  attr :guest, :map, required: true
  attr :meeting, :map, required: true
  attr :status, :string, required: true
  attr :token, :string, required: true
  attr :response, :string, required: true

  @spec confirm(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm(assigns) do
    ~H"""
    <% accepting? = @status == "accepted" %>
    <TokenPage.shell>
      <div class={[
        "mx-auto flex h-16 w-16 items-center justify-center rounded-token-full",
        accepting? && "bg-green-100 text-green-600",
        !accepting? && "bg-amber-100 text-amber-600"
      ]}>
        <.icon
          name={if accepting?, do: "hero-check-circle", else: "hero-x-circle"}
          class="h-9 w-9"
        />
      </div>

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

      <form method="post" action={"/guest/#{@token}/#{@response}"} class="mt-6">
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <button
          type="submit"
          class={[
            "w-full rounded-token-xl px-6 py-3 text-token-base font-semibold text-white",
            accepting? && "bg-green-600 hover:bg-green-700",
            !accepting? && "bg-amber-500 hover:bg-amber-600"
          ]}
        >
          {if accepting?,
            do: dgettext("booking", "Confirm attendance"),
            else: dgettext("booking", "Confirm decline")}
        </button>
      </form>
    </TokenPage.shell>
    """
  end

  @doc "Shown after a guest successfully accepts or declines their invitation."
  attr :guest, :map, required: true
  attr :meeting, :map, required: true
  attr :status, :string, required: true
  attr :toggle_url, :string, required: true
  attr :toggle_label, :atom, required: true

  @spec confirmation(map()) :: Phoenix.LiveView.Rendered.t()
  def confirmation(assigns) do
    ~H"""
    <% accepted? = @status == "accepted" %>
    <TokenPage.shell>
      <div class={[
        "mx-auto flex h-16 w-16 items-center justify-center rounded-token-full",
        accepted? && "bg-green-100 text-green-600",
        !accepted? && "bg-amber-100 text-amber-600"
      ]}>
        <.icon name={if accepted?, do: "hero-check-circle", else: "hero-x-circle"} class="h-9 w-9" />
      </div>

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

      <p class="mt-6 text-token-sm text-tymeslot-500">
        {if accepted?,
          do: dgettext("booking", "Changed your mind?"),
          else: dgettext("booking", "Able to make it after all?")}
        <.link href={@toggle_url} class="font-medium text-turquoise-600 underline">
          {if @toggle_label == :decline,
            do: dgettext("booking", "Decline instead"),
            else: dgettext("booking", "Accept instead")}
        </.link>
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
        "booking",
        "The invitation link may have expired or already been used. Please contact the meeting host."
      )
    } />
    """
  end

  @doc "Shown when the visitor has made too many requests in a short window."
  @spec too_many_requests(map()) :: Phoenix.LiveView.Rendered.t()
  def too_many_requests(assigns), do: TokenPage.too_many_requests(assigns)

  defp format_when(meeting),
    do: MeetingTimeFormat.format_when(meeting, meeting.attendee_timezone)
end
