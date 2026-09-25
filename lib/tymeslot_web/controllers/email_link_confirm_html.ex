defmodule TymeslotWeb.EmailLinkConfirmHTML do
  @moduledoc """
  The landing page for a one-time link sent by email (email verification,
  email change).

  Opening such a link only renders this page; the change itself happens when
  the button is pressed, as a CSRF-protected POST back to the same URL. Mail
  scanners that prefetch every link in a message therefore cannot consume the
  token before the recipient gets to it.
  """

  use TymeslotWeb, :html

  attr :action, :string, required: true, doc: "The URL the confirmation is POSTed to"
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true
  attr :button, :string, required: true

  @spec confirm(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm(assigns) do
    ~H"""
    <main class="flex min-h-screen items-center justify-center bg-linear-to-br from-turquoise-50 via-white to-cyan-50 p-4">
      <div class="w-full max-w-md rounded-token-2xl bg-white p-8 text-center shadow-glass-lg">
        <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-turquoise-100 text-turquoise-600">
          <.icon name={@icon} class="h-9 w-9" />
        </div>

        <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">{@title}</h1>
        <p class="mt-2 text-token-base text-tymeslot-600">{@body}</p>

        <form method="post" action={@action} class="mt-6">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <.action_button type="submit" class="w-full">{@button}</.action_button>
        </form>
      </div>
    </main>
    """
  end
end
