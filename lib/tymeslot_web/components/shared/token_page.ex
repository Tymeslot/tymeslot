defmodule TymeslotWeb.Components.Shared.TokenPage do
  @moduledoc """
  Shared chrome and terminal states for the public, unauthenticated pages
  reached from a tokenised link in an email.

  Two controllers render these: `TymeslotWeb.GuestRsvpController` (a guest
  answering an invitation) and `TymeslotWeb.SeatController` (a group-booking
  participant managing their own seat). Both are a single centred card on a
  plain background and share the rate-limited dead end, so the card and that
  page live here rather than once per controller.

  `invalid/1` is the seat flow's spent-link page and takes its body copy as an
  attribute; the guest flow has its own, since it tells an unknown link apart
  from a meeting that no longer takes responses.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  The centred-card page chrome every token page sits inside.
  """
  slot :inner_block, required: true
  @spec shell(map()) :: Phoenix.LiveView.Rendered.t()
  def shell(assigns) do
    ~H"""
    <main class="flex min-h-screen items-center justify-center bg-linear-to-br from-turquoise-50 via-white to-cyan-50 p-4">
      <div class="w-full max-w-md rounded-token-2xl bg-white p-8 text-center shadow-glass-lg">
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end

  @doc """
  Shown when the token is missing, invalid, or already used up.

  `:body` is the flow's own wording for what the spent link was.
  """
  attr :body, :string, required: true
  @spec invalid(map()) :: Phoenix.LiveView.Rendered.t()
  def invalid(assigns) do
    ~H"""
    <.shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-tymeslot-100 text-tymeslot-500">
        <.icon name="hero-link-slash" class="h-9 w-9" />
      </div>
      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking", "This link is no longer valid")}
      </h1>
      <p class="mt-2 text-token-base text-tymeslot-600">{@body}</p>
    </.shell>
    """
  end

  @doc """
  Shown when the visitor has made too many requests in a short window.
  """
  @spec too_many_requests(map()) :: Phoenix.LiveView.Rendered.t()
  def too_many_requests(assigns) do
    ~H"""
    <.shell>
      <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-amber-100 text-amber-600">
        <.icon name="hero-clock" class="h-9 w-9" />
      </div>
      <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
        {dgettext("booking", "Too many attempts")}
      </h1>
      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext("booking", "Please wait a moment and try again.")}
      </p>
    </.shell>
    """
  end
end
